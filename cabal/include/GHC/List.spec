module spec GHC.List where 

--measure len :: forall a. [a] -> Int
--len ([])     = 0
--len (y:ys)   = 1 + len(ys)
--
--invariant {v: [a] | len(v) >= 0 }