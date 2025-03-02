
module Agda.TypeChecking.Monad.Context where

import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Trans.Maybe
import Control.Monad.Writer

import qualified Data.List as List
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Monoid

import Agda.Syntax.Abstract.Name
import Agda.Syntax.Common
import Agda.Syntax.Concrete.Name (LensInScope(..))
import Agda.Syntax.Internal
import Agda.Syntax.Position
import Agda.Syntax.Scope.Base
import Agda.Syntax.Scope.Monad (getLocalVars, setLocalVars)

import Agda.TypeChecking.Monad.Base
import Agda.TypeChecking.Monad.Debug
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Monad.Open
import Agda.TypeChecking.Monad.Options
import Agda.TypeChecking.Monad.State

import Agda.Utils.Except
import Agda.Utils.Functor
import Agda.Utils.Lens
import Agda.Utils.List ((!!!), downFrom)
import Agda.Utils.ListT
import Agda.Utils.Maybe
import Agda.Utils.Monad
import Agda.Utils.Pretty
import Agda.Utils.Size

import Agda.Utils.Impossible

-- * Modifying the context

-- | Modify a 'Context' in a computation.
{-# SPECIALIZE modifyContext :: (Context -> Context) -> TCM a -> TCM a #-}
modifyContext :: MonadTCEnv tcm => (Context -> Context) -> tcm a -> tcm a
modifyContext f = localTC $ \e -> e { envContext = f $ envContext e }

-- | Change to top (=empty) context. Resets the checkpoints.
{-# SPECIALIZE inTopContext :: TCM a -> TCM a #-}
safeInTopContext :: MonadTCM tcm => tcm a -> tcm a
safeInTopContext cont = do
  locals <- liftTCM $ getLocalVars
  liftTCM $ setLocalVars []
  a <- modifyContext (const [])
        $ locallyTC eCurrentCheckpoint (const 0)
        $ locallyTC eCheckpoints (const $ Map.singleton 0 IdS) cont
  liftTCM $ setLocalVars locals
  return a

-- | Change to top (=empty) context, but don't update the checkpoints. Totally
--   not safe!
{-# SPECIALIZE inTopContext :: TCM a -> TCM a #-}
inTopContext :: (MonadTCEnv m, ReadTCState m) => m a -> m a
inTopContext cont =
  locallyScope scopeLocals (const []) $
    modifyContext (const []) cont

-- | Delete the last @n@ bindings from the context.
--
--   Doesn't update checkpoints! Use `updateContext rho (drop n)` instead,
--   for an appropriate substitution `rho`.
{-# SPECIALIZE escapeContext :: Int -> TCM a -> TCM a #-}
escapeContext :: MonadTCM tcm => Int -> tcm a -> tcm a
escapeContext n = modifyContext $ drop n

-- * Manipulating checkpoints --

-- | Add a new checkpoint. Do not use directly!
checkpoint
  :: (MonadDebug tcm, MonadTCM tcm, MonadFresh CheckpointId tcm)
  => Substitution -> tcm a -> tcm a
checkpoint sub k = do
  unlessDebugPrinting $ reportSLn "tc.cxt.checkpoint" 105 $ "New checkpoint {"
  old     <- viewTC eCurrentCheckpoint
  oldMods <- useTC  stModuleCheckpoints
  chkpt <- fresh
  unlessDebugPrinting $ verboseS "tc.cxt.checkpoint" 105 $ do
    cxt <- getContextTelescope
    cps <- viewTC eCheckpoints
    let cps' = Map.insert chkpt IdS $ fmap (applySubst sub) cps
        prCps cps = vcat [ pshow c <+> ": " <+> pretty s | (c, s) <- Map.toList cps ]
    reportSDoc "tc.cxt.checkpoint" 105 $ return $ nest 2 $ vcat
      [ "old =" <+> pshow old
      , "new =" <+> pshow chkpt
      , "sub =" <+> pretty sub
      , "cxt =" <+> pretty cxt
      , "old substs =" <+> prCps cps
      , "new substs =" <?> prCps cps'
      ]
  x <- flip localTC k $ \ env -> env
    { envCurrentCheckpoint = chkpt
    , envCheckpoints       = Map.insert chkpt IdS $
                              fmap (applySubst sub) (envCheckpoints env)
    }
  newMods <- useTC stModuleCheckpoints
  -- Set the checkpoint for introduced modules to the old checkpoint when the
  -- new one goes out of scope. #2897: This isn't actually sound for modules
  -- created under refined parent parameters, but as long as those modules
  -- aren't named we shouldn't look at the checkpoint. The right thing to do
  -- would be to not store these modules in the checkpoint map, but todo..
  stModuleCheckpoints `setTCLens` Map.union oldMods (old <$ Map.difference newMods oldMods)
  unlessDebugPrinting $ reportSLn "tc.cxt.checkpoint" 105 "}"
  return x

-- | Get the substitution from the context at a given checkpoint to the current context.
checkpointSubstitution :: MonadTCEnv tcm => CheckpointId -> tcm Substitution
checkpointSubstitution = maybe __IMPOSSIBLE__ return <=< checkpointSubstitution'

-- | Get the substitution from the context at a given checkpoint to the current context.
checkpointSubstitution' :: MonadTCEnv tcm => CheckpointId -> tcm (Maybe Substitution)
checkpointSubstitution' chkpt = viewTC (eCheckpoints . key chkpt)

-- | Get substitution @Γ ⊢ ρ : Γm@ where @Γ@ is the current context
--   and @Γm@ is the module parameter telescope of module @m@.
--
--   In case the we don't have a checkpoint for @m@ we return the identity
--   substitution.
--   This is ok for instance if we are outside module @m@ (in which case we
--   have to supply all module parameters to any symbol defined within @m@ we
--   want to refer).
getModuleParameterSub :: (MonadTCEnv m, ReadTCState m) => ModuleName -> m Substitution
getModuleParameterSub m = do
  mcp <- (^. stModuleCheckpoints . key m) <$> getTCState
  maybe (return IdS) checkpointSubstitution mcp


-- * Adding to the context

{-# SPECIALIZE addCtx :: Name -> Dom Type -> TCM a -> TCM a #-}
class MonadTCEnv m => MonadAddContext m where
  -- | @addCtx x arg cont@ add a variable to the context.
  --
  --   Chooses an unused 'Name'.
  --
  --   Warning: Does not update module parameter substitution!
  addCtx :: Name -> Dom Type -> m a -> m a

  -- | Update the context. Requires a substitution from the old context to the
  --   new.
  updateContext :: Substitution -> (Context -> Context) -> m a -> m a

  withFreshName :: Range -> ArgName -> (Name -> m a) -> m a

-- | Default implementation of addCtx in terms of updateContext
defaultAddCtx :: MonadAddContext m => Name -> Dom Type -> m a -> m a
defaultAddCtx x a ret = do
  q <- viewTC eQuantity
  let ce = (x,) <$> inverseApplyQuantity q a
  updateContext (raiseS 1) (ce :) ret

withFreshName_ :: (MonadAddContext m) => ArgName -> (Name -> m a) -> m a
withFreshName_ = withFreshName noRange

instance MonadAddContext m => MonadAddContext (MaybeT m) where
  addCtx x a = MaybeT . addCtx x a . runMaybeT
  updateContext sub f = MaybeT . updateContext sub f . runMaybeT
  withFreshName r x = MaybeT . withFreshName r x . (runMaybeT .)

instance MonadAddContext m => MonadAddContext (ExceptT e m) where
  addCtx x a = mkExceptT . addCtx x a . runExceptT
  updateContext sub f = mkExceptT . updateContext sub f . runExceptT
  withFreshName r x = mkExceptT . withFreshName r x . (runExceptT .)

instance MonadAddContext m => MonadAddContext (ReaderT r m) where
  addCtx x a = ReaderT . (addCtx x a .) . runReaderT
  updateContext sub f = ReaderT . (updateContext sub f .) . runReaderT
  withFreshName r x ret = ReaderT $ \env -> withFreshName r x $ \n -> runReaderT (ret n) env

instance (Monoid w, MonadAddContext m) => MonadAddContext (WriterT w m) where
  addCtx x a = WriterT . addCtx x a . runWriterT
  updateContext sub f = WriterT . updateContext sub f . runWriterT
  withFreshName r x = WriterT . withFreshName r x . (runWriterT .)

instance MonadAddContext m => MonadAddContext (StateT r m) where
  addCtx x a = StateT . (addCtx x a .) . runStateT
  updateContext sub f = StateT . (updateContext sub f .) . runStateT
  withFreshName r x ret = StateT $ \s -> withFreshName r x $ \n -> runStateT (ret n) s

instance MonadAddContext m => MonadAddContext (ListT m) where
  addCtx x a = liftListT $ addCtx x a
  updateContext sub f = liftListT $ updateContext sub f
  withFreshName r x ret = ListT $ withFreshName r x $ \n -> runListT (ret n)

instance MonadAddContext TCM where
  addCtx x a ret = do
    when (not $ isNoName x) $ do
      registerForShadowing x
      ys <- getContextNames
      forM_ ys $ \y ->
        when (not (isNoName y) && sameRoot x y) $ tellShadowing x y
    defaultAddCtx x a ret

    where
      -- add x to the map of possibly shadowed names
      registerForShadowing x = modifyTCLens stShadowingNames $ Map.insert x []

      -- register the fact that x possibly shadows the name y
      tellShadowing x y = modifyTCLens stShadowingNames $ Map.adjust (x:) y

  updateContext sub f = modifyContext f . checkpoint sub

  withFreshName r x m = freshName r x >>= m

addRecordNameContext
  :: (MonadAddContext m, MonadFresh NameId m)
  => Dom Type -> m b -> m b
addRecordNameContext dom ret = do
  x <- setNotInScope <$> freshRecordName
  addCtx x dom ret

-- | Various specializations of @addCtx@.
{-# SPECIALIZE addContext :: b -> TCM a -> TCM a #-}
class AddContext b where
  addContext :: (MonadAddContext m) => b -> m a -> m a
  contextSize :: b -> Nat

-- | Wrapper to tell 'addContext' not to mark names as
--   'NotInScope'. Used when adding a user-provided, but already type
--   checked, telescope to the context.
newtype KeepNames a = KeepNames a

instance {-# OVERLAPPABLE #-} AddContext a => AddContext [a] where
  addContext = flip (foldr addContext)
  contextSize = sum . map contextSize

instance AddContext (Name, Dom Type) where
  addContext = uncurry addCtx
  contextSize _ = 1

instance AddContext (Dom (Name, Type)) where
  addContext = addContext . distributeF
  contextSize _ = 1

instance AddContext (Dom (String, Type)) where
  addContext = addContext . distributeF
  contextSize _ = 1

instance AddContext ([Name], Dom Type) where
  addContext (xs, dom) = addContext (bindsToTel' id xs dom)
  contextSize (xs, _) = length xs

instance AddContext ([WithHiding Name], Dom Type) where
  addContext ([]                 , dom) = id
  addContext (WithHiding h x : xs, dom) =
    addContext (x , mapHiding (mappend h) dom) .
    addContext (xs, raise 1 dom)
  contextSize (xs, _) = length xs

instance AddContext ([Arg Name], Type) where
  addContext (xs, t) = addContext ((map . fmap) unnamed xs :: [NamedArg Name], t)
  contextSize (xs, _) = length xs

instance AddContext ([NamedArg Name], Type) where
  addContext ([], _)     = id
  addContext (x : xs, t) =
    addContext (namedArg x, t <$ domFromNamedArgName x) .
    addContext (xs, raise 1 t)
  contextSize (xs, _) = length xs

instance AddContext (String, Dom Type) where
  addContext (s, dom) ret =
    withFreshName noRange s $ \x -> addCtx (setNotInScope x) dom ret
  contextSize _ = 1

instance AddContext (KeepNames String, Dom Type) where
  addContext (KeepNames s, dom) ret =
    withFreshName noRange s $ \ x -> addCtx x dom ret
  contextSize _ = 1

instance AddContext (Dom Type) where
  addContext dom = addContext ("_" :: String, dom)
  contextSize _ = 1

instance AddContext Name where
  addContext x = addContext (x, __DUMMY_DOM__)
  contextSize _ = 1

instance {-# OVERLAPPING #-} AddContext String where
  addContext s = addContext (s, __DUMMY_DOM__)
  contextSize _ = 1

instance AddContext (KeepNames Telescope) where
  addContext (KeepNames tel) ret = loop tel where
    loop EmptyTel          = ret
    loop (ExtendTel t tel) = underAbstraction' KeepNames t tel loop
  contextSize (KeepNames tel) = size tel

instance AddContext Telescope where
  addContext tel ret = loop tel where
    loop EmptyTel          = ret
    loop (ExtendTel t tel) = underAbstraction' id t tel loop
  contextSize = size

-- | Go under an abstraction.  Do not extend context in case of 'NoAbs'.
{-# SPECIALIZE underAbstraction :: Subst t a => Dom Type -> Abs a -> (a -> TCM b) -> TCM b #-}
underAbstraction :: (Subst t a, MonadAddContext m) => Dom Type -> Abs a -> (a -> m b) -> m b
underAbstraction = underAbstraction' id

underAbstraction' :: (Subst t a, MonadAddContext m, AddContext (name, Dom Type)) =>
                     (String -> name) -> Dom Type -> Abs a -> (a -> m b) -> m b
underAbstraction' _ _ (NoAbs _ v) k = k v
underAbstraction' wrap t a k = underAbstractionAbs' wrap t a k

-- | Go under an abstraction, treating 'NoAbs' as 'Abs'.
underAbstractionAbs :: (Subst t a, MonadAddContext m) => Dom Type -> Abs a -> (a -> m b) -> m b
underAbstractionAbs = underAbstractionAbs' id

underAbstractionAbs'
  :: (Subst t a, MonadAddContext m, AddContext (name, Dom Type))
  => (String -> name) -> Dom Type -> Abs a -> (a -> m b) -> m b
underAbstractionAbs' wrap t a k = addContext (wrap $ realName $ absName a, t) $ k $ absBody a
  where
    realName s = if isNoName s then "x" else argNameToString s

-- | Go under an abstract without worrying about the type to add to the context.
{-# SPECIALIZE underAbstraction_ :: Subst t a => Abs a -> (a -> TCM b) -> TCM b #-}
underAbstraction_ :: (Subst t a, MonadAddContext m) => Abs a -> (a -> m b) -> m b
underAbstraction_ = underAbstraction __DUMMY_DOM__

getLetBindings :: MonadTCM tcm => tcm [(Name,(Term,Dom Type))]
getLetBindings = do
  bs <- asksTC envLetBindings
  forM (Map.toList bs) $ \ (n,o) -> (,) n <$> getOpen o

-- | Add a let bound variable
{-# SPECIALIZE addLetBinding' :: Name -> Term -> Dom Type -> TCM a -> TCM a #-}
addLetBinding' :: MonadTCEnv m => Name -> Term -> Dom Type -> m a -> m a
addLetBinding' x v t ret = do
    vt <- makeOpen (v, t)
    flip localTC ret $ \e -> e { envLetBindings = Map.insert x vt $ envLetBindings e }

-- | Add a let bound variable
{-# SPECIALIZE addLetBinding :: ArgInfo -> Name -> Term -> Type -> TCM a -> TCM a #-}
addLetBinding :: MonadTCEnv m => ArgInfo -> Name -> Term -> Type -> m a -> m a
addLetBinding info x v t0 ret = addLetBinding' x v (defaultArgDom info t0) ret


-- * Querying the context

-- | Get the current context.
{-# SPECIALIZE getContext :: TCM [Dom (Name, Type)] #-}
getContext :: MonadTCEnv m => m [Dom (Name, Type)]
getContext = asksTC envContext

-- | Get the size of the current context.
{-# SPECIALIZE getContextSize :: TCM Nat #-}
getContextSize :: (Applicative m, MonadTCEnv m) => m Nat
getContextSize = length <$> asksTC envContext

-- | Generate @[var (n - 1), ..., var 0]@ for all declarations in the context.
{-# SPECIALIZE getContextArgs :: TCM Args #-}
getContextArgs :: (Applicative m, MonadTCEnv m) => m Args
getContextArgs = reverse . zipWith mkArg [0..] <$> getContext
  where mkArg i dom = var i <$ argFromDom dom

-- | Generate @[var (n - 1), ..., var 0]@ for all declarations in the context.
{-# SPECIALIZE getContextTerms :: TCM [Term] #-}
getContextTerms :: (Applicative m, MonadTCEnv m) => m [Term]
getContextTerms = map var . downFrom <$> getContextSize

-- | Get the current context as a 'Telescope'.
{-# SPECIALIZE getContextTelescope :: TCM Telescope #-}
getContextTelescope :: (Applicative m, MonadTCEnv m) => m Telescope
getContextTelescope = telFromList' nameToArgName . reverse <$> getContext

-- | Get the names of all declarations in the context.
{-# SPECIALIZE getContextNames :: TCM [Name] #-}
getContextNames :: (Applicative m, MonadTCEnv m) => m [Name]
getContextNames = map (fst . unDom) <$> getContext

-- | get type of bound variable (i.e. deBruijn index)
--
{-# SPECIALIZE lookupBV' :: Nat -> TCM (Maybe (Dom (Name, Type))) #-}
lookupBV' :: MonadTCEnv m => Nat -> m (Maybe (Dom (Name, Type)))
lookupBV' n = do
  ctx <- getContext
  return $ raise (n + 1) <$> ctx !!! n

{-# SPECIALIZE lookupBV :: Nat -> TCM (Dom (Name, Type)) #-}
lookupBV :: MonadTCEnv m => Nat -> m (Dom (Name, Type))
lookupBV n = do
  let failure = do
        ctx <- getContext
        fail $ "de Bruijn index out of scope: " ++ show n ++
               " in context " ++ prettyShow (map (fst . unDom) ctx)
  maybeM failure return $ lookupBV' n

{-# SPECIALIZE domOfBV :: Nat -> TCM (Dom Type) #-}
domOfBV :: (Applicative m, MonadTCEnv m) => Nat -> m (Dom Type)
domOfBV n = fmap snd <$> lookupBV n

{-# SPECIALIZE typeOfBV :: Nat -> TCM Type #-}
typeOfBV :: (Applicative m, MonadTCEnv m) => Nat -> m Type
typeOfBV i = unDom <$> domOfBV i

{-# SPECIALIZE nameOfBV' :: Nat -> TCM (Maybe Name) #-}
nameOfBV' :: (Applicative m, MonadTCEnv m) => Nat -> m (Maybe Name)
nameOfBV' n = fmap (fst . unDom) <$> lookupBV' n

{-# SPECIALIZE nameOfBV :: Nat -> TCM Name #-}
nameOfBV :: (Applicative m, MonadTCEnv m) => Nat -> m Name
nameOfBV n = fst . unDom <$> lookupBV n

-- | Get the term corresponding to a named variable. If it is a lambda bound
--   variable the deBruijn index is returned and if it is a let bound variable
--   its definition is returned.
{-# SPECIALIZE getVarInfo :: Name -> TCM (Term, Dom Type) #-}
getVarInfo :: MonadTCEnv m => Name -> m (Term, Dom Type)
getVarInfo x =
    do  ctx <- getContext
        def <- asksTC envLetBindings
        case List.findIndex ((==x) . fst . unDom) ctx of
            Just n -> do
                t <- domOfBV n
                return (var n, t)
            _       ->
                case Map.lookup x def of
                    Just vt -> getOpen vt
                    _       -> fail $ "unbound variable " ++ prettyShow (nameConcrete x) ++
                                " (id: " ++ prettyShow (nameId x) ++ ")"
