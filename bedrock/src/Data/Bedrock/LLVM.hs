{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Data.Bedrock.LLVM ( compile ) where

import           Control.Applicative          (Applicative)
import           Control.Monad.Reader
import           Data.Map                     (Map)
import qualified Data.Map                     as Map
import qualified Data.Set                     as Set
import qualified LLVM.Wrapper.BitWriter       as LLVM
import           LLVM.Wrapper.Core            (Value)
import qualified LLVM.Wrapper.Core            as LLVM

import           Data.Bedrock
import           Data.Bedrock.GlobalVariables (allRegisters)

data Env = Env
    { envNodeMapping :: Map NodeName Int
    , envVariables   :: Map Variable LLVM.Value
    , envForeigns    :: Map String Foreign
    , envGlobals     :: Map String LLVM.Value
    , envBuilder     :: LLVM.Builder
    , envFunction    :: Value
    , envModule      :: LLVM.Module
    , envWordTy      :: LLVM.Type
    , envPointerTy   :: LLVM.Type
    , envVoidTy      :: LLVM.Type
    }

newtype Gen a = Gen { unGen :: ReaderT Env IO a }
    deriving
        ( Monad, Applicative, Functor, MonadReader Env
        , MonadIO )








compile :: Module -> FilePath -> IO ()
compile bedrock dst = do
    m <- LLVM.moduleCreateWithName "lhc"
    LLVM.setDataLayout m "p:64:64:64"
    cx <- LLVM.getGlobalContext
    voidTy <- LLVM.voidTypeInContext cx

    mapM_ (compileForeign m) (modForeigns bedrock)

    runGen bedrock m cx $ prepareFunctions (functions bedrock) $ \llvmFns -> do

        zipWithM_ compileFunction (functions bedrock) llvmFns




        let mainFnTy = LLVM.functionType voidTy [] False
        mainFn <- liftIO $ LLVM.addFunction m "main" mainFnTy
        entry <- liftIO $ LLVM.appendBasicBlock mainFn ""
        bld <- liftIO $ LLVM.createBuilder
        setFunction mainFn $ setBuilder bld $ do
            Just entryFn <- liftIO $ LLVM.getNamedFunction m (uniqueName $ entryPoint bedrock)

            liftIO $ LLVM.positionAtEnd bld entry
            pointerTy <- asks envPointerTy
            zeroes <- replicateM nMainArgs (liftIO $ LLVM.constPointerNull pointerTy)
            call <- buildCall entryFn (zeroes) ""
            liftIO $ LLVM.setInstructionCallConv call LLVM.Fast
            buildRetVoid
            return ()


    LLVM.writeBitcodeToFile m dst
    --LLVM.destroyModule m
    return ()
  where
    nMainArgs = head [ length (fnArguments fn) | fn <- functions bedrock, fnName fn == entryPoint bedrock ]

cTypeToLLVM :: CType -> IO LLVM.Type
cTypeToLLVM cType = do
    cx <- LLVM.getGlobalContext
    case cType of
        CVoid -> LLVM.voidTypeInContext cx
        I8    -> LLVM.intTypeInContext cx 8
        I32   -> LLVM.intTypeInContext cx 32
        I64   -> LLVM.intTypeInContext cx 64
        IWord -> LLVM.intTypeInContext cx 64
        CPointer ty -> do
            tyRef <- cTypeToLLVM ty
            return $ LLVM.pointerType tyRef 0

typesToLLVM :: [Type] -> Gen LLVM.Type
typesToLLVM []        = asks envVoidTy
typesToLLVM [NodePtr] = asks envPointerTy
typesToLLVM [FramePtr] = asks envPointerTy
typesToLLVM [Primitive ty] = liftIO $ cTypeToLLVM ty
typesToLLVM _         = error $ "typesToLLVM: Unsupported type"

compileForeign :: LLVM.Module -> Foreign -> IO ()
compileForeign m f = do

    ret <- cTypeToLLVM (foreignReturn f)
    args <- mapM cTypeToLLVM (foreignArguments f)
    let fnTy = LLVM.functionType ret args False
    LLVM.addFunction m (foreignName f) fnTy
    return ()

prepareFunctions :: [Function] -> ([Value] -> Gen a) -> Gen a
prepareFunctions fs0 action = worker [] fs0
  where
    worker acc []     = action (reverse acc)
    worker acc (f:fs) = prepareFunction f (\llvmFn -> worker (llvmFn:acc) fs)

prepareFunction :: Function -> (Value -> Gen a) -> Gen a
prepareFunction fn action = do
    m <- asks envModule
    fnReturnTy <- typesToLLVM (fnResults fn)
    fnArgTys <- forM (fnArguments fn) $ \arg -> typesToLLVM [variableType arg]
    let fnTy = LLVM.functionType fnReturnTy fnArgTys False
    llvmFn <- liftIO $ LLVM.addFunction m (uniqueName (fnName fn)) fnTy
    liftIO $ LLVM.setLinkage llvmFn LLVM.PrivateLinkage
    liftIO $ LLVM.setFunctionCallConv llvmFn LLVM.Fast

    fnArgs <- forM (zip [0..] (fnArguments fn)) $ \(nth, arg) -> do
        let param = LLVM.getParam llvmFn nth
        liftIO $ LLVM.setValueName param (uniqueVariable arg)
        return (arg, param)

    bindVariables fnArgs (action llvmFn)

compileFunction :: Function -> Value -> Gen ()
compileFunction fn llvmFn = do
    entry <- liftIO $ LLVM.appendBasicBlock llvmFn "entry"
    bld <- liftIO $ LLVM.createBuilder
    liftIO $ LLVM.positionAtEnd bld entry
    setFunction llvmFn $ setBuilder bld $
        compileBlock (fnBody fn)

compileBlock :: Block -> Gen ()
compileBlock block =
    case block of
        Bind _ Store{} _ -> error "LLVM: Unsupported: @store"
        Bind _ GCAllocate{} _ -> error "LLVM: Unsupported: @GCAllocate"
        Bind _ Alloc{} _ -> error "LLVM: Unsupported: @alloc"
        Bind _ GCBegin{} _ -> error "LLVM: Unsupported: @gc_begin"
        Bind _ GCEnd{} _ -> error "LLVM: Unsupported: @gc_end"
        Bind _ GCMark{} _ -> error "LLVM: Unsupported: @gc_mark"
        Bind _ GCMarkNode{} _ -> error "LLVM: Unsupported: @gc_mark_node"



        Bind binds (CCall fName args) rest -> do
            f <- asks ((Map.! fName) . envForeigns)

            argValues <- mapM resolve args

            m <- asks envModule
            Just fn <- liftIO $ LLVM.getNamedFunction m fName

            typedArgs <- zipWithM asCType argValues (foreignArguments f)

            ret <- buildCall fn typedArgs ""
            typedRet <- fromCType ret (foreignReturn f)

            case binds of
                [bind] -> bindVariable bind typedRet $ compileBlock rest
                _      -> compileBlock rest
        Bind [bind] (TypeCast arg) rest -> do
            value <- resolve arg
            case (variableType bind, variableType arg) of
                (Primitive CPointer{}, Primitive CPointer{}) ->
                    bindVariable bind value $ compileBlock rest
                
                (Primitive (CPointer ty), Primitive{}) -> do
                    --typedValue <- asPointer value
                    typedValue <- asCType value (CPointer ty) -- :: Value -> CType -> Gen Value
                    bindVariable bind typedValue $ compileBlock rest
                (Primitive ty, Primitive CPointer{}) -> do
                    typedValue <- asCType value ty
                    bindVariable bind typedValue $ compileBlock rest
                
                (Primitive{}, ptr) | ptr `elem` [NodePtr,FramePtr] -> do
                    typedValue <- asWord value
                    bindVariable bind typedValue $ compileBlock rest
                (ptr, Primitive{}) | ptr `elem` [NodePtr,FramePtr] -> do
                    typedValue <- asPointer value
                    bindVariable bind typedValue $ compileBlock rest
                _ -> bindVariable bind value $ compileBlock rest
        Bind [bind] (MkNode name []) rest -> do
            value <- resolveNodeName name
            bindVariable bind value $ compileBlock rest
        Bind [bind] (Literal lit) rest -> do
            value <- resolveLiteral lit
            bindVariable bind value $ compileBlock rest
        Bind [bind] (Load _constant ptr nth) rest -> do
            value <- compileLoad ptr nth
            bindVariable bind value $ compileBlock rest

        Bind [] (Write word nth arg) rest -> do
            compileWrite word nth arg
            compileBlock rest
        Bind [bind] (Address word nth) rest -> do
            wordValue <- resolve word
            ptr <- asPointer wordValue
            offset <- constWord (fromIntegral nth)
            offsetPtr <- buildGEP ptr [offset] ""
            bindVariable bind offsetPtr $ compileBlock rest


        Bind [] (Application fn args) rest -> do
            llvmFn <- resolveFunction fn
            llvmArgs <- mapM resolve args
            llvmCall <- buildCall llvmFn llvmArgs ""
            liftIO $ LLVM.setInstructionCallConv llvmCall LLVM.Fast
            compileBlock rest
        Bind [ret] (Application fn args) rest -> do
            llvmFn <- resolveFunction fn
            llvmArgs <- mapM resolve args
            llvmCall <- buildCall llvmFn llvmArgs ""
            liftIO $ LLVM.setInstructionCallConv llvmCall LLVM.Fast
            bindVariable ret llvmCall $ compileBlock rest
        Return [] ->
            buildRetVoid >> return ()
        Return [var] -> do
            value <- resolve var
            buildRet value
            return ()
        Panic{} -> -- XXX: Ignoring the msg for now.
            buildUnreachable >> return ()

        Bind [var] (ReadGlobal reg) rest -> do
            global <- asks ((Map.! reg) . envGlobals)
            globalValue <- asPointer =<< buildLoad global ""
            bindVariable var globalValue $ compileBlock rest
        Bind [] (WriteGlobal reg var) rest -> do
            value <- asWord =<< resolve var
            global <- asks ((Map.! reg) . envGlobals)
            buildStore value global
            compileBlock rest

        Bind [bind] (Add a b) rest -> do
            value <- compileAdd a b
            bindVariable bind value $ compileBlock rest

        Case scrut _defaultBranch alts -> do
            self <- asks envFunction
            defBlock <- liftIO $ LLVM.appendBasicBlock self "default"
            defBuilder <- liftIO $ LLVM.createBuilder
            liftIO $ LLVM.positionAtEnd defBuilder defBlock
            liftIO $ LLVM.buildUnreachable defBuilder

            value <- resolve scrut
            switch <- buildSwitch value defBlock (length alts)
            forM_ alts $ \(Alternative pattern branch) -> do
                branchBlock <- liftIO $ LLVM.appendBasicBlock self "branch"
                branchBuilder <- liftIO $ LLVM.createBuilder
                liftIO $ LLVM.positionAtEnd branchBuilder branchBlock
                setBuilder branchBuilder $ compileBlock branch
                pValue <- compilePattern pattern
                liftIO $ LLVM.addCase switch pValue branchBlock
            return ()
        TailCall fn args -> do
            llvmFn <- resolveFunction fn
            llvmArgs <- mapM resolve args
            llvmCall <- buildCall llvmFn llvmArgs ""
            liftIO $ LLVM.setTailCall llvmCall True
            liftIO $ LLVM.setInstructionCallConv llvmCall LLVM.Fast
            buildRetVoid
            return ()
        Exit -> buildRetVoid >> return ()
        _ -> error $ "LLVM expr: " ++ show block

compileAdd :: Variable -> Variable -> Gen Value
compileAdd a b = do
    a' <- resolve a
    b' <- resolve b
    buildAdd a' b' ""

compileWrite :: Variable -> Int -> Variable -> Gen Value
compileWrite word nth var = do
    resolved <- resolve var
    argValue <- asCType resolved IWord
    
    wordValue <- resolve word
    ptr <- asPointer wordValue
    
    offset <- constWord (fromIntegral nth)
    offsetPtr <- buildGEP ptr [offset] ""
    buildStore argValue offsetPtr

compileLoad :: Variable -> Int -> Gen Value
compileLoad ptr nth = do
    wordValue <- resolve ptr

    ptrValue    <- asPointer wordValue
    offset      <- constWord (fromIntegral nth)
    offsetValue <- buildGEP ptrValue [offset] ""
    buildLoad offsetValue ""

compilePattern :: Pattern -> Gen LLVM.Value
compilePattern pattern = do
    case pattern of
        LitPat (LiteralInt i) -> constWord i
        LitPat LiteralString{} ->
            error "LLVM: Strings not allowed in patterns"
        NodePat name []       -> resolveNodeName name
        NodePat{} ->
            error "LLVM: Invalid node in pattern."

resolveLiteral :: Literal -> Gen Value
resolveLiteral lit = do
    case lit of
        LiteralInt i      -> constWord i
        LiteralString str -> buildGlobalStringPtr str ""
        



-------------------------------------------------
-- Helpers

runGen :: Module -> LLVM.Module -> LLVM.Context -> Gen a -> IO a
runGen m llvmModule cx gen = runReaderT (unGen gen) =<< mkEnv m llvmModule cx

bindVariable :: Variable -> LLVM.Value -> Gen a -> Gen a
bindVariable variable value = local $ \env ->
    env{ envVariables = Map.insert variable value (envVariables env) }

bindVariables :: [(Variable, LLVM.Value)] -> Gen a -> Gen a
bindVariables [] = id
bindVariables ((variable, value):rest) =
    bindVariable variable value . bindVariables rest

resolve :: Variable -> Gen LLVM.Value
resolve variable = do
    m <- asks envVariables
    case Map.lookup variable m of
        Nothing    -> error $ "LLVM.resolve: " ++ show variable
        Just value -> return value

resolveNodeName :: NodeName -> Gen LLVM.Value
resolveNodeName nodeName = do
    wordTy <- asks envWordTy
    m <- asks envNodeMapping
    case Map.lookup nodeName m of
        Nothing  -> error $ "LLVM.resolveNodeName: " ++ show nodeName
        Just idx -> return $ LLVM.constInt wordTy (fromIntegral idx) False

resolveFunction :: Name -> Gen Value
resolveFunction name = do
    m <- asks envModule
    Just fn <- liftIO $ LLVM.getNamedFunction m (uniqueName name)
    return fn

constWord :: Integer -> Gen LLVM.Value
constWord word = do
    wordTy <- asks envWordTy
    return $ LLVM.constInt wordTy (fromIntegral word) False

setBuilder :: LLVM.Builder -> Gen a -> Gen a
setBuilder bld = local $ \env -> env{ envBuilder = bld }

setFunction :: LLVM.Value -> Gen a -> Gen a
setFunction fn = local $ \env -> env{ envFunction = fn }

withBuilder :: (LLVM.Builder -> Gen a) -> Gen a
withBuilder action = action =<< asks envBuilder

mkEnv :: Module -> LLVM.Module -> LLVM.Context -> IO Env
mkEnv m llvmModule cx = do
    wordTy <- LLVM.intTypeInContext cx 64
    voidTy <- LLVM.voidTypeInContext cx
    let regs = Set.toList $ allRegisters m
    globals <- forM regs $ \reg -> do
        global <- LLVM.addGlobal llvmModule wordTy reg
        -- The JIT compiler doesn't support thread local globals.
        --LLVM.setThreadLocal global 1
        LLVM.setVisibility global LLVM.HiddenVisibility
        LLVM.setInitializer global (LLVM.constInt wordTy 0 False)
        return global
    return Env
        { envNodeMapping = Map.fromList $ flip zip [0..] $
            [ ConstructorName name | NodeDefinition name _tys <- nodes m ] ++
            [ FunctionName (fnName fn) blanks
            | fn <- functions m, blanks <- [0..length (fnArguments fn)] ]
        , envVariables = Map.empty
        , envForeigns = Map.fromList
            [ (foreignName f, f) | f <- modForeigns m ]
        , envGlobals = Map.fromList $ zip regs globals
        , envFunction = error "envFunction not defined"
        , envBuilder = error "envBuilder not defined"
        , envModule = llvmModule
        , envWordTy = wordTy
        , envPointerTy = LLVM.pointerType wordTy 0
        , envVoidTy = voidTy
        }

uniqueName :: Name -> String
uniqueName name =
    nameIdentifier name ++ "_" ++ show (nameUnique name)

uniqueVariable :: Variable -> String
uniqueVariable = uniqueName . variableName



-------------------------------------------------
-- LLVM Wrappers
-- cTypeToLLVM :: CType -> IO LLVM.Type
asCType :: Value -> CType -> Gen Value
asCType value cType = do
    case cType of
        CPointer ty -> do
            ptr <- asPointer value
            llvmType <- liftIO $ cTypeToLLVM ty
            buildTruncOrBitCast ptr (LLVM.pointerType llvmType 0) ""
        IWord -> do
            word <- asWord value
            llvmType <- liftIO $ cTypeToLLVM cType
            buildZExtOrBitCast word llvmType ""
        _ -> do
            word <- asWord value
            llvmType <- liftIO $ cTypeToLLVM cType
            buildTruncOrBitCast word llvmType ""

fromCType :: Value -> CType -> Gen Value
fromCType value cType = do
    case cType of
        CPointer ty -> do
            llvmType <- liftIO $ cTypeToLLVM ty
            asPointer =<< buildTruncOrBitCast value (LLVM.pointerType llvmType 0) ""
        _ -> do
            llvmType <- liftIO $ cTypeToLLVM cType
            asWord =<< buildTruncOrBitCast value llvmType ""


asWord :: Value -> Gen Value
asWord value = do
    ty <- liftIO $ LLVM.typeOf value
    kind <- liftIO $ LLVM.getTypeKind ty
    name <- liftIO $ LLVM.getValueName value
    case kind of
        LLVM.IntegerTypeKind -> return value
        LLVM.PointerTypeKind -> castPtrToWord value
        _ -> error $ "LLVM: Unknown kind: " ++ show (kind, name)

asPointer :: Value -> Gen Value
asPointer value = do
    ty <- liftIO $ LLVM.typeOf value
    kind <- liftIO $ LLVM.getTypeKind ty
    case kind of
        LLVM.IntegerTypeKind -> castWordToPtr value
        LLVM.PointerTypeKind -> return value
        _ -> error "LLVM: Unknown type kind."


castWordToPtr :: Value -> Gen Value
castWordToPtr value = do
    wordTy <- asks envWordTy
    let pType = LLVM.pointerType wordTy 0
    buildIntToPtr value pType ""
    --return $ LLVM.constIntToPtr value pType

castPtrToWord :: Value -> Gen Value
castPtrToWord value = do
    wordTy <- asks envWordTy
    buildPtrToInt value wordTy ""
    --return $ LLVM.constPtrToInt value wordTy

buildRetVoid :: Gen Value
buildRetVoid = withBuilder $ \bld -> do
    liftIO $ LLVM.buildRetVoid bld

buildRet :: Value -> Gen Value
buildRet ret = withBuilder $ \bld -> do
    liftIO $ LLVM.buildRet bld ret

buildUnreachable :: Gen Value
buildUnreachable = withBuilder $ \bld ->
    liftIO $ LLVM.buildUnreachable bld

buildIntToPtr :: Value -> LLVM.Type -> String -> Gen Value
buildIntToPtr intValue ptrType name = withBuilder $ \bld ->
    liftIO $ LLVM.buildIntToPtr bld intValue ptrType name

buildPtrToInt :: Value -> LLVM.Type -> String -> Gen Value
buildPtrToInt ptrValue intType name = withBuilder $ \bld ->
    liftIO $ LLVM.buildPtrToInt bld ptrValue intType name

_buildBitCast :: Value -> LLVM.Type -> String -> Gen Value
_buildBitCast value ty name = withBuilder $ \bld ->
    liftIO $ LLVM.buildBitCast bld value ty name

buildTruncOrBitCast :: Value -> LLVM.Type -> String -> Gen Value
buildTruncOrBitCast value ty name = withBuilder $ \bld ->
    liftIO $ LLVM.buildTruncOrBitCast bld value ty name

buildZExtOrBitCast :: Value -> LLVM.Type -> String -> Gen Value
buildZExtOrBitCast value ty name = withBuilder $ \bld ->
    liftIO $ LLVM.buildZExtOrBitCast bld value ty name

buildGEP :: Value -> [Value] -> String -> Gen Value
buildGEP ptrValue indices name = withBuilder $ \bld ->
    liftIO $ LLVM.buildGEP bld ptrValue indices name

buildLoad :: Value -> String -> Gen Value
buildLoad ptrValue name = withBuilder $ \bld ->
    liftIO $ LLVM.buildLoad bld ptrValue name

buildSwitch :: Value -> LLVM.BasicBlock -> Int -> Gen Value
buildSwitch scrut defaultBranch nBranches = withBuilder $ \bld ->
    liftIO $ LLVM.buildSwitch bld scrut defaultBranch (fromIntegral nBranches)

_buildArrayAlloca :: LLVM.Type -> Value -> String -> Gen Value
_buildArrayAlloca ty val name = withBuilder $ \bld ->
    liftIO $ LLVM.buildArrayAlloca bld ty val name

_buildArrayMalloc :: LLVM.Type -> Value -> String -> Gen Value
_buildArrayMalloc ty val name = withBuilder $ \bld ->
    liftIO $ LLVM.buildArrayMalloc bld ty val name

buildStore :: Value -> Value -> Gen Value
buildStore val ptr = withBuilder $ \bld ->
    liftIO $ LLVM.buildStore bld val ptr

buildCall :: Value -> [Value] -> String -> Gen Value
buildCall fn args name = withBuilder $ \bld ->
    liftIO $ LLVM.buildCall bld fn args name

buildAdd :: Value -> Value -> String -> Gen Value
buildAdd a b name = withBuilder $ \bld ->
    liftIO $ LLVM.buildAdd bld a b name

buildGlobalStringPtr :: String -> String -> Gen Value
buildGlobalStringPtr str name = withBuilder $ \bld ->
    liftIO $ LLVM.buildGlobalStringPtr bld str name

