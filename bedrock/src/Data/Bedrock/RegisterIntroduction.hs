{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NoMonadFailDesugaring #-}
module Data.Bedrock.RegisterIntroduction
    ( registerIntroduction ) where

import           Control.Applicative  (Applicative, pure, (<$>), (<*>))
import           Control.Monad.Reader
import           Control.Monad.State
import           Data.Map             (Map)
import qualified Data.Map             as Map

import           Data.Bedrock
import           Data.Bedrock.Misc

data Env = Env
    { envRegisters :: Map Variable [Variable]
    , envSignatures :: Map Name [Variable]
    }

newtype Uniq a = Uniq { unUniq :: ReaderT Env (State AvailableNamespace) a }
    deriving ( Monad, MonadReader Env, MonadState AvailableNamespace
             , Functor, Applicative )

registerIntroduction :: Module -> Module
registerIntroduction m = evalState (runReaderT (unUniq (uniqModule m)) env) st
  where
    env = Env
        { envRegisters = Map.empty
        , envSignatures = Map.fromList
            [ (fnName, fnArguments) | Function{..} <- functions m ]
        }
    st = modNamespace m



newUnique :: Maybe Type -> Uniq Int
newUnique mbTy = do
    ns <- get
    let (idNum, ns') = case mbTy of
            Nothing -> newGlobalID ns
            Just ty -> newIDByType ns ty
    put ns'
    return idNum

newName :: Maybe Type -> Name -> Uniq Name
newName mbTy name = do
    u <- newUnique mbTy
    return name{ nameUnique = u }

lower :: Variable -> Uniq a -> Uniq a
lower old action =
    case variableType old of
        StaticNode n -> do
            newNames <- replicateM n (newName (Just Node) (variableName old))
            let newVars =
                    [ Variable name IWord | name <- newNames ]
            local (\env -> env{envRegisters = Map.insert old newVars (envRegisters env)})
                action
        Node -> error $ "RegisterIntroduction: Found node: " ++ show old
        _  -> action

lowerMany :: [Variable] -> Uniq a -> Uniq a
lowerMany xs action = foldr lower action xs

resolve :: Variable -> Uniq [Variable]
resolve var = asks $ Map.findWithDefault [var] var . envRegisters

resolveMany :: [Variable] -> Uniq [Variable]
resolveMany = fmap concat . mapM resolve

resolveArgs :: Name -> [Variable] -> Uniq [Variable]
resolveArgs fn vars = do
    fnArgs <- asks (\env -> envSignatures env Map.! fn)
    let n = sum
            [ case variableType arg of
                StaticNode size -> size
                _ -> 1
            | arg <- fnArgs ]
    resolved <- resolveMany vars
    return (take n $ resolved ++ repeat undefinedVariable)

undefinedVariable :: Variable
undefinedVariable = Variable (Name [] "undefined" 0) IWord

uniqModule :: Module -> Uniq Module
uniqModule m =
    --lowerMany [ name | NodeDefinition name _args <- nodes m ] $
    do
        ns  <- mapM uniqNode (nodes m)
        fns <- mapM uniqFunction (functions m)
        namespace <- get
        return Module
            { modForeigns = modForeigns m
            , nodes = ns
            , modLayouts = modLayouts m
            , entryPoint = entryPoint m
            , functions = fns
            , modNamespace = namespace
            }

uniqNode :: NodeDefinition -> Uniq NodeDefinition
uniqNode = return {-
uniqNode (NodeDefinition name args) =
    NodeDefinition <$> resolveName name <*> pure args
-}
uniqFunction :: Function -> Uniq Function
uniqFunction (Function name attrs args rets body) = lowerMany args $
    Function
        <$> pure name -- resolveName name
        <*> pure attrs
        <*> resolveMany args
        <*> pure rets
        <*> (Bind [undefinedVariable] Undefined <$> uniqBlock body)

bindMany :: [(Variable, Variable)] -> Block -> Block
bindMany lst rest =
    foldr (\(bind, var) -> Bind [bind] (TypeCast var)) rest lst

uniqBlock :: Block -> Uniq Block
uniqBlock block =
    case block of
        Case scrut Nothing [Alternative (NodePat UnboxedTupleName args) branch] -> do
            scruts <- resolve scrut
            lowerMany args $ do
                flatVars <- resolveMany args
                bindMany (zip flatVars scruts)
                    <$> uniqBlock branch
        Case scrut mbBranch alts -> do
            scruts <- resolve scrut
            case scruts of
                [] -> pure Exit
                (tag:args) ->
                    Case tag
                        <$> uniqMaybe uniqBlock mbBranch
                        <*> mapM (uniqAlternative args) alts
        Bind [bind] (TypeCast var) rest -> lower bind $ do
            nodeBinds <- resolve bind
            varArgs   <- resolve var
            bindMany (zip nodeBinds varArgs)
                <$> uniqBlock rest
        Bind [bind] (Literal lit) rest -> lower bind $
            Bind
                <$> resolve bind
                <*> pure (Literal lit)
                <*> uniqBlock rest
        Bind [bind] (MkNode UnboxedTupleName nodeArgs) rest -> lower bind $ do
            nodeBinds <- resolve bind
            rest' <- uniqBlock rest
            return $
                bindMany (zip nodeBinds nodeArgs) rest'
        Bind [bind] (MkNode nodeName nodeArgs) rest -> lower bind $ do
            (tagBind:nodeBinds) <- resolve bind
            rest' <- uniqBlock rest
            return $
                Bind [tagBind] (MkNode nodeName []) $
                bindMany (zip nodeBinds nodeArgs) rest'
        Bind [obj] (Fetch ptr) (Case scrut mbBranch alts) | scrut == obj ->
          lower obj $ do
            (tag:_) <- resolve obj
            Bind [tag] (Load ptr 0)
              <$> (Case tag
                    <$> uniqMaybe uniqBlock mbBranch
                    <*> mapM (uniqAlternative' ptr tag) alts)
        -- Bind binds (Fetch ptr) rest -> lowerMany binds $ do
        --     binds' <- resolveMany binds
        --     rest' <- uniqBlock rest
        --     return $ foldr (\(n,b) -> Bind [b] (Load ptr n)) rest' (zip [0..] binds')
        Bind [bind] (StoreAlloc nodeName tys) rest -> do
            rest' <- uniqBlock rest
            return $
                Bind [] (Alloc $ 1 + length tys) $
                Bind [bind] (StoreAlloc nodeName tys) rest'
        Bind [bind] (Store nodeName args) rest -> do
            args' <- resolveMany args
            rest' <- uniqBlock rest
            return $
                Bind [] (Alloc $ 1 + length args) $
                Bind [bind] (StoreAlloc nodeName (map variableType args')) $
                Bind [] (StoreWrite bind args') rest'
        Bind binds simple rest -> lowerMany binds $
            Bind
                <$> resolveMany binds
                <*> uniqExpression simple
                <*> uniqBlock rest
        Recursive binds rest -> lowerMany binds $
          Recursive
            <$> resolveMany binds
            <*> uniqBlock rest
        Return vars ->
            Return <$> resolveMany vars
        Raise var ->
            pure $ Raise var
        TailCall fn vars ->
            TailCall fn <$> resolveArgs fn vars
        Invoke fn vars ->
            Invoke fn <$> resolveMany vars
        Exit -> pure Exit
        Panic msg -> pure (Panic msg)

uniqAlternative :: [Variable] -> Alternative -> Uniq Alternative
uniqAlternative args (Alternative pattern branch) =
    case pattern of
        LitPat{} -> Alternative pattern <$> uniqBlock branch
        NodePat nodeName vars -> lowerMany vars $ do
            flatVars <- resolveMany vars
            Alternative
                <$> pure (NodePat nodeName [])
                <*> (bindMany (zip flatVars (args ++ repeat undefinedVariable))
                        <$> uniqBlock branch)
        -- VarPat var ->
        --     Alternative
        --         <$> pure (VarPat var)
        --         <*> uniqBlock branch

uniqAlternative' :: Variable -> Variable -> Alternative -> Uniq Alternative
uniqAlternative' ptr tag (Alternative pattern branch) =
  case pattern of
    LitPat{} -> Alternative pattern <$> uniqBlock branch
    NodePat nodeName vars -> lowerMany vars $ do
      flatVars <- resolveMany vars
      let load idx | idx == length flatVars &&
                     variableType (last flatVars) == NodePtr =
                       LoadLastPtr ptr tag idx
                   | otherwise = Load ptr idx
          bind rest =
            foldr (\(bind, idx) -> Bind [bind] (load idx)) rest
              (zip flatVars [1..])
      Alternative
        <$> pure (NodePat nodeName [])
        <*> (bind <$> uniqBlock branch)


uniqMaybe :: (a -> Uniq a) -> Maybe a -> Uniq (Maybe a)
uniqMaybe fn obj =
    case obj of
        Nothing  -> return Nothing
        Just val -> Just <$> fn val

uniqExpression :: Expression -> Uniq Expression
uniqExpression expr =
    case expr of
        Application fn vars ->
            Application fn <$> resolveArgs fn vars
        Write dst idx ptr -> do
            ret <- resolve ptr
            case ret of
              [] -> pure (Write dst idx ptr)
              (tag:_) -> pure (Write dst idx tag)
        CCall fn vars ->
            CCall fn <$> resolveMany vars
        Catch exh exhArgs fn fnArgs ->
            Catch
                <$> pure exh <*> resolveMany exhArgs
                <*> pure fn <*> resolveMany fnArgs
        InvokeReturn fn vars ->
          InvokeReturn fn <$> resolveMany vars
        Builtin "isIndirection" [PVariable obj] -> do
          (tag:_) <- resolve obj
          pure (Builtin "isIndirection" [PVariable tag])
        Builtin{} -> pure expr
        Literal{} -> pure expr
