{-# LANGUAGE NoMonomorphismRestriction, TypeSynonymInstances, FlexibleInstances, TupleSections, DeriveDataTypeable, ScopedTypeVariables  #-}

{- Raw description of pure types (without dependencies on GHC), suitable for
 - parsing from raw strings, and functions for converting between bare types
 - and real refinements. -}

module Language.Haskell.Liquid.Bare (
    BType (..)
  , BareType (..)
  , mkRefTypes
  , mkMeasureSpec
  , mkAssumeSpec
  , mkIds
  , isDummyBind
  )
where

import GHC hiding (lookupName)	
import Outputable
import Var
import PrelNames

import Type       (liftedTypeKind)
import HscTypes   (HscEnv)
import qualified CoreMonad as CM 
import GHC.Paths (libdir)

import System.Environment (getArgs)
import DynFlags (defaultDynFlags)
import HscMain
import TypeRep
import TysWiredIn
import DataCon  (dataConWorkId)
import BasicTypes (TupleSort (..), Boxity (..))
import TcRnDriver (tcRnLookupRdrName, tcRnLookupName) 

import TysPrim          (intPrimTyCon)
import TysWiredIn       (listTyCon, intTy, intTyCon, boolTyCon, intDataCon, trueDataCon, falseDataCon)
import TyCon (tyConName, isAlgTyCon)
import DataCon (dataConName)



import Name             (mkInternalName)

import OccName          (mkTyVarOcc)
import Unique           (getKey, getUnique, initTyVarUnique)
import Data.List (sort)
import Data.Char (isUpper)
import ErrUtils
-- import Control.Monad
import Data.Traversable (forM)
import Control.Monad.Reader hiding (forM)
import Data.Generics.Schemes
import Data.Generics.Aliases
import Data.Data hiding (TyCon, tyConName)
import qualified Data.Map as M

import Language.Haskell.Liquid.GhcMisc2
import Language.Haskell.Liquid.Fixpoint
import Language.Haskell.Liquid.RefType
import qualified Language.Haskell.Liquid.Measure as Ms
import Language.Haskell.Liquid.Misc
import qualified Control.Exception as Ex

------------------------------------------------------------------
------------------- API: Bare Refinement Types -------------------
------------------------------------------------------------------

data BType b r 
  = BVar b r
  | BFun b (BType b r) (BType b r)
  | BCon b [(BType b r)] r
  | BConApp b [(BType b r)] [r] r
  | BAll b (BType b r)
  | BLst (BType b r) r
  | BTup [(BType b r)] r
  | BClass b [(BType b r)]
  deriving (Data, Typeable)

instance Show (BType b r) where
 show (BConApp b bts rs r) = undefined
 show ts                   = undefined

type BareType = BType String Reft  

mkRefTypes :: HscEnv -> [BareType] -> IO [RefType]
mkRefTypes env bs = runReaderT (mapM mkRefType bs) env

{-
mkRefType x
  = do  b <- mapSymbol symbolToSymbol x
        b' <- ofBareType b
        return $ canonRefType b'
-}

mkRefType = liftM canonRefType . ofBareType
                        
mkMeasureSpec :: HscEnv -> Ms.MSpec BareType Symbol -> IO ([(Var, RefType)], [(Symbol, RefType)])
mkMeasureSpec env m = runReaderT mkSpec env
  where mkSpec = mkMeasureSort m >>= mkMeasureDCon >>= return . Ms.dataConTypes

mkAssumeSpec :: HscEnv -> [(Symbol, BareType)] -> IO [(Var, RefType)]
mkAssumeSpec env xbs = runReaderT mkAspec env
  where mkAspec = forM xbs $ \(x, b) -> liftM2 (,) (lookupGhcId $ (symbolString x)) (mkRefType b)

mkIds :: HscEnv -> [Name] -> IO [Var]
mkIds env ns = runReaderT (mapM lookupGhcId ns) env

------------------------------------------------------------------
-------------------- Type Checking Raw Strings -------------------
------------------------------------------------------------------

tcExpr ::  FilePath -> String -> IO Type
tcExpr f s = 
    runGhc (Just libdir) $ do
      df   <- getSessionDynFlags
      setSessionDynFlags df
      cm0  <- compileToCoreModule f
      setContext [IIModule (cm_module cm0)]
      env  <- getSession
      r    <- CM.liftIO $ hscTcExpr env s 
      return r

fileEnv f 
  = runGhc (Just libdir) $ do
      df    <- getSessionDynFlags
      setSessionDynFlags df
      cm0  <- compileToCoreModule f
      setContext [IIModule (cm_module cm0)]
      env   <- getSession
      return env


-----------------------------------------------------------------
------ Querying GHC for Id, Type, Class, Con etc. ---------------
-----------------------------------------------------------------

class Outputable a => GhcLookup a where
  lookupName :: HscEnv -> a -> IO Name

instance GhcLookup String where
  lookupName = stringToName

instance GhcLookup Name where
  lookupName _  = return

lookupGhcThing :: (GhcLookup a) => String -> (TyThing -> Maybe b) -> a -> BareM b
lookupGhcThing name f x 
  = do env     <- ask
       (_,res) <- liftIO $ tcRnLookupName env =<< lookupName env x
       case f `fmap` res of
         Just (Just z) -> 
           return z
         _      -> 
           liftIO $ ioError $ userError $ "lookupGhcThing unknown " ++ name ++ " : " ++ (showPpr x)

lookupGhcThingToSymbol :: (TyThing -> Maybe Symbol) -> String -> BareM Symbol
lookupGhcThingToSymbol f x 
  = do env     <- ask
       m <- liftIO $ lookupNameStr env x 
       case m of 
          Just n -> do  (_,res) <- liftIO $ tcRnLookupName env n
                        case f `fmap` res of
                          Just (Just z) -> return z
                          _      -> return $ S x
          _      -> return $ S x

lookupNameStr :: HscEnv -> String -> IO (Maybe Name)
lookupNameStr env k 
  = case M.lookup k wiredIn of 
      Just n  -> return (Just n)
      Nothing -> stringToNameEnvStr env k

stringToNameEnvStr :: HscEnv -> String -> IO ( Maybe Name)
stringToNameEnvStr env s 
    = do L _ rn         <- hscParseIdentifier env s
         (_, lookupres) <- tcRnLookupRdrName env rn
         case lookupres of
           Just (n:_) -> return (Just n)
           _          -> return Nothing


lookupGhcTyCon = lookupGhcThing "TyCon" ftc 
  where ftc (ATyCon x) = Just x
        ftc _          = Nothing

lookupGhcClass = lookupGhcThing "Class" ftc 
  where ftc (ATyCon x) = tyConClass_maybe x 
        ftc _          = Nothing

lookupGhcDataCon = lookupGhcThing "DataCon" fdc 
  where fdc (ADataCon x) = Just x
        fdc _            = Nothing

lookupGhcId s 
  = lookupGhcThing "Id" fid s
  where fid (AnId x)     = Just x
        fid (ADataCon x) = Just $ dataConWorkId x
        fid _            = Nothing

stringToName :: HscEnv -> String -> IO Name
stringToName env k 
  = case M.lookup k wiredIn of 
      Just n  -> return n
      Nothing -> stringToNameEnv env k

stringToNameEnv :: HscEnv -> String -> IO Name
stringToNameEnv env s 
    = do L _ rn         <- hscParseIdentifier env s
         (_, lookupres) <- tcRnLookupRdrName env rn
         case lookupres of
           Just (n:_) -> return n
           _          -> errorstar $ "Bare.lookupName cannot find name for: " ++ s
symbolToSymbol :: Symbol -> BareM Symbol
symbolToSymbol (S s) 
  = lookupGhcThingToSymbol fid s
  where fid (AnId x)     = Just $ mkSymbol x
        fid (ADataCon x) = Just $ mkSymbol $ dataConWorkId x
        fid _            = Nothing

wiredIn :: M.Map String Name
wiredIn = M.fromList $
  [ ("GHC.Integer.smallInteger" , smallIntegerName) 
  , ("GHC.Num.fromInteger", fromIntegerName)
  , ("GHC.Types.I#" , dataConName intDataCon)
  , ("GHC.Prim.Int#", tyConName intPrimTyCon) ]
  
------------------------------------------------------------------------
----------------- Transforming Raw Strings using GHC Env ---------------
------------------------------------------------------------------------

type BareM a = ReaderT HscEnv IO a

ofBareType :: BareType -> BareM RefType
ofBareType (BVar a r) 
  = return $ RVar (stringRTyVar a) r
ofBareType (BFun x t1 t2) 
  = liftM2 (RFun (rbind x)) (ofBareType t1) (ofBareType t2)
ofBareType (BAll a t) 
  = liftM  (RAll (stringRTyVar a)) (ofBareType t)
ofBareType (BConApp tc ts rs r) 
  = liftM2 (bareTCApp r rs) (lookupGhcTyCon tc) (mapM ofBareType ts)
ofBareType (BCon tc ts r)
  = liftM2 (bareTCApp r []) (lookupGhcTyCon tc) (mapM ofBareType ts)
ofBareType (BClass c ts)
  = liftM2 RClass (lookupGhcClass c) (mapM ofBareType ts)
ofBareType (BLst t r) 
  = liftM (bareTCApp r [] listTyCon . (:[])) (ofBareType t)
ofBareType (BTup ts r)
  = liftM (bareTCApp r [] c) (mapM ofBareType ts)
    where c = tupleTyCon BoxedTuple (length ts)

-- TODO: move back to RefType
bareTCApp :: Reft -> [Reft] -> TyCon -> [RefType] -> RefType 
bareTCApp r rs c ts 
  = RConApp (RTyCon c []) ts rs r
{-
bareTyCon c 
  | isAlgTyCon c
  = RAlgTyCon c (RDataTyCon () [])
  | otherwise
		= RPrimTyCon c
-}
rbind ""    = RB dummySymbol
rbind s     = RB $ stringSymbol s


stringRTyVar = rTyVar . stringTyVar 

isDummyBind (RB s) = s == dummySymbol 


mkMeasureDCon :: (Data t) => Ms.MSpec t Symbol -> BareM (Ms.MSpec t DataCon)
mkMeasureDCon m = (forM (measureCtors m) $ \n -> liftM (n,) (lookupGhcDataCon n))
                  >>= (return . mkMeasureDCon_ m)

mkMeasureDCon_ :: Ms.MSpec t Symbol -> [(String, DataCon)] -> Ms.MSpec t DataCon
mkMeasureDCon_ m ndcs = m' {Ms.ctorMap = cm'}
  where m'  = fmap tx m
        cm' = M.mapKeys (dataConSymbol . tx) $ Ms.ctorMap m'
        tx  = mlookup (M.fromList ndcs) . symbolString

measureCtors ::  Ms.MSpec t Symbol -> [String]
measureCtors = nubSort . fmap (symbolString . Ms.ctor) . concat . M.elems . Ms.ctorMap 

mkMeasureSort :: Ms.MSpec BareType a -> BareM (Ms.MSpec RefType a)
mkMeasureSort (Ms.MSpec cm mm) 
  = liftM (Ms.MSpec cm) $ forM mm $ \m -> 
      liftM (\s' -> m {Ms.sort = s'}) (ofBareType (Ms.sort m))


class MapSymbol a where
  mapSymbol :: (Symbol -> BareM Symbol) -> a -> BareM a

instance MapSymbol Reft where
  mapSymbol f (Reft(s, rs)) = liftM2 (\s' rs' -> Reft(s', rs')) (f s) (mapM (mapSymbol f) rs)

instance MapSymbol Refa where
  mapSymbol f (RConc p)     = liftM RConc (mapSymbol f p)
  mapSymbol f (RKvar s sub) = liftM2 RKvar (f s) (return sub)

instance MapSymbol Pred where
  mapSymbol f (PAnd ps)       = liftM PAnd (mapM (mapSymbol f) ps)
  mapSymbol f (POr ps)        = liftM POr (mapM (mapSymbol f) ps)
  mapSymbol f (PNot p)        = liftM PNot (mapSymbol f p)
  mapSymbol f (PImp p1 p2)    = liftM2 PImp (mapSymbol f p1) (mapSymbol f p2)
  mapSymbol f (PIff p1 p2)    = liftM2 PIff (mapSymbol f p1) (mapSymbol f p2)
  mapSymbol f (PBexp e)       = liftM PBexp (mapSymbol f e)
  mapSymbol f (PAtom b e1 e2) = liftM2 (PAtom b) (mapSymbol f e1) (mapSymbol f e2)
  mapSymbol f (PAll _ _)      = error "mapSymbol PAll"
  mapSymbol _ p               = return p 

instance MapSymbol Expr where
  mapSymbol f (EVar s)       = liftM EVar (f s)
  mapSymbol f (EDat s so)    = liftM2 EDat (f s) (return so)
  mapSymbol f (ELit s so)    = liftM2 ELit (f s) (return so)
  mapSymbol f (EApp s es)    = liftM2 EApp (f s) (mapM (mapSymbol f) es)
  mapSymbol f (EBin b e1 e2) = liftM2 (EBin b) (mapSymbol f e1) (mapSymbol f e2)
  mapSymbol f (EIte p e1 e2) = liftM3 EIte (mapSymbol f p) (mapSymbol f e1) (mapSymbol f e2)
  mapSymbol f (ECst e s)     = liftM2 ECst (mapSymbol f e) (return s) 
  mapSymbol _ e              = return e

instance MapSymbol BareType where
  mapSymbol f (BVar b r)          = liftM (BVar b) (mapSymbol f r) 
  mapSymbol f (BFun b t1 t2)      = liftM2 (BFun b) (mapSymbol f t1) (mapSymbol f t2)
  mapSymbol f (BCon b ts r)       = liftM2 (BCon b) (mapM (mapSymbol f) ts) (mapSymbol f r)
  mapSymbol f (BConApp b ts rs r) = liftM3 (BConApp b) (mapM (mapSymbol f) ts) (mapM (mapSymbol f) rs) (mapSymbol f r)
  mapSymbol f (BAll b t)          = liftM (BAll b) (mapSymbol f t)
  mapSymbol f (BLst t r)          = liftM2 BLst (mapSymbol f t) (mapSymbol f r)
  mapSymbol f (BTup ts r)         = liftM2 BTup (mapM (mapSymbol f) ts) (mapSymbol f r)
  mapSymbol f (BClass b ts)       = liftM (BClass b) (mapM (mapSymbol f) ts)  
