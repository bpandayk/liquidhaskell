{-# LANGUAGE TupleSections #-}

module Language.Haskell.Liquid.Bounds (

    Bound(..), 

    RBound, RRBound,

    RBEnv, RRBEnv,

    makeBound

	) where

import Text.PrettyPrint.HughesPJ

import Data.List (partition)
import Data.Maybe
import Data.Hashable
import Data.Monoid
import Data.Bifunctor

import qualified Data.HashMap.Strict as M
import Control.Applicative                      ((<$>))

import Language.Fixpoint.Types
import Language.Fixpoint.Misc  

import Language.Haskell.Liquid.Types
import Language.Haskell.Liquid.RefType

data Bound t e = Bound { bname   :: LocSymbol    -- * The name of the bound
                       , bparams :: [(LocSymbol, t)]  -- * These are abstract refinements, for now
                       , bargs   :: [(LocSymbol, t)]  -- * These are value variables
                       , bbody   :: e            -- * The body of the bound
                       }	

type RBound     = RRBound RSort
type RRBound ty = Bound ty Pred

type RBEnv = M.HashMap LocSymbol RBound 
type RRBEnv ty = M.HashMap LocSymbol (RRBound ty) 


instance Hashable (Bound t e) where
	hashWithSalt i = hashWithSalt i . bname


instance (PPrint e) => (Show (Bound t e)) where
	show = showpp

instance (PPrint e) => (PPrint (Bound t e)) where
	pprint (Bound s ps xs e) =   text "bound" <+> pprint s <+> pprint (fst <$> ps) <+> text "=" <+>
	                             pprint_bsyms (fst <$> xs) <+> pprint e




instance Bifunctor Bound where
	first  f (Bound s ps xs e) = Bound s (mapSnd f <$> ps) (mapSnd f <$> xs) e
	second f (Bound s ps xs e) = Bound s ps xs (f e)


makeBound :: (PPrint r, UReftable r)
         => RRBound RSort -> [Symbol] -> (RRType r) -> (RRType r)
makeBound (Bound _ ps xs p) qs t 
  = RRTy [(dummySymbol, ct)] mempty OCons t
  where 
  	ct = traceShow "BOUND" $ booz (zip (val . fst <$> ps) qs) (bkImp [] p) xs

  	bkImp acc (PImp p q) = bkImp (p:acc) q
  	bkImp acc p          = p:acc


booz :: (PPrint r, UReftable r) => [(Symbol, Symbol)] -> [Pred] -> [(LocSymbol, RSort)] -> RRType r
booz penv (q:qs) xts = go xts
  where
    (ps, rs) = partitionPs [] [] penv qs 
    mkt t x = ofRSort t `strengthen` ofUReft (U (Reft(val x, [])) 
    	                                        (Pr $ M.lookupDefault [] (val x) ps) mempty)
    tp t x = ofRSort t `strengthen` ofUReft (U (Reft(val x, RConc <$> rs)) 
    	                                        (Pr $ M.lookupDefault [] (val x) ps) mempty)
    tq t x = ofRSort t `strengthen` makeRef penv x q 
    go [] = error "booz.go"
    go [(x, t)]      = RFun dummySymbol (tp t x) (tq t x) mempty 
    go ((x, t):xtss) = RFun (val x) (mkt t x) (go xtss) mempty
booz _ _ _ = error "booz"

partitionPs qs rs _    [] 
  = (M.fromListWith (++) qs, rs)
partitionPs qs rs penv (q@(PBexp (EApp p es)):ps) | isJust $ lookup (val p) penv
  = partitionPs ((x, [boo penv q]):qs) rs penv ps
  where x = (\(EVar x) -> x) $ last es
partitionPs qs rs penv (r:ps)
  = partitionPs qs (r:rs) penv ps

{-
foo :: (PPrint r, UReftable r) => [(Symbol, Symbol)] -> Pred -> [(LocSymbol, RSort)] -> RRType r
foo penv (PImp p q) [(v, t)] 
  = RFun dummySymbol tp tq mempty
  where 
    t' = ofRSort t
    tp = t' `strengthen` makeRef penv v p   
    tq = t' `strengthen` makeRef penv v q 

foo penv (PImp z zs) ((x, t):xs)  
  = RFun (val x) t' (foo penv zs xs) mempty 
  where
  	t' = ofRSort t `strengthen` makeRef penv x z 

foo _ _ _ 
  = error "foo" -- NV TODO
-}
makeRef :: (UReftable r) => [(Symbol, Symbol)] -> LocSymbol -> Pred -> r
makeRef penv v tt@(PAnd rs) | not (null pps)   
  = ofUReft (U (Reft(val v, RConc <$> rrs)) (traceShow ("HOHO" ++ show tt) r) mempty)
  where r      = Pr (boo penv <$> pps) -- [PV q (PVProp ()) e (((), dummySymbol,) <$> es')]
        (pps, rrs) = traceShow "PARTITIONED" $ partition isPApp rs

        isPApp r@(PBexp (EApp p _))  = traceShow ("IS PAPP " ++ show (r, penv) ) $ isJust $ lookup (val p) penv
        isPApp _                   = False

makeRef penv v rr | isPApp rr   
  = ofUReft (U (Reft(val v, [])) r mempty)
  where r      = Pr [boo penv rr] -- [PV q (PVProp ()) e (((), dummySymbol,) <$> es')]

        isPApp r@(PBexp (EApp p _))  = traceShow ("IS PAPP " ++ show (r, penv) ) $ isJust $ lookup (val p) penv
        isPApp _                   = False

makeRef _ v p 
  = ofReft (Reft(val v, [RConc $ traceShow "PPP" p]))
--   = ofReft ( U (Reft(val v, [])) (Pr [PV q (PVProp ()) (last es) es]) mempty)


boo penv (PBexp (EApp p es)) = PV q (PVProp ()) e (((), dummySymbol,) <$> es')
  where
  	EVar e = last es
  	es'    = init es
  	Just q = lookup (val p) penv 

boo _ _ = error "BOBOBOBO" 

pprint_bsyms [] = text ""
pprint_bsyms xs = text "\\" <+> pprint xs <+> text "->"

instance Eq (Bound t e) where
	b1 == b2 = (bname b1) == (bname b2)  


