-- | This module defines the 'Patch' class, which is used by Reflex to manage
-- changes to 'Reflex.Class.Incremental' values.
{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Reflex.Patch
  ( Patch (..)
  , PatchDMap (..)
  , ComposeMaybe (..)
  , PatchMap (..)
  , Group (..)
  , Additive
  , AdditivePatch (..)
  ) where

import Control.Monad.Identity
import Data.Dependent.Map (DMap, GCompare (..))
import qualified Data.Dependent.Map as DMap
import Data.Functor.Constant
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Semigroup (Semigroup (..), stimesIdempotentMonoid, (<>))

-- | A 'Patch' type represents a kind of change made to a datastructure.
class Patch p where
  type PatchTarget p :: *
  -- | Apply the patch @p a@ to the value @a@.  If no change is needed, return
  -- 'Nothing'.
  apply :: p -> PatchTarget p -> Maybe (PatchTarget p)

-- | We can't use @Compose Maybe@ instead of 'ComposeMaybe', because that would
-- make the 'f' parameter have a nominal type role.  We need f to be
-- representational so that we can use safe 'coerce'.
newtype ComposeMaybe f a = ComposeMaybe { getComposeMaybe :: Maybe (f a) }

deriving instance Functor f => Functor (ComposeMaybe f)

instance Patch (Identity a) where
  type PatchTarget (Identity a) = a
  apply (Identity a) _ = Just a

-- | A set of changes to a 'DMap'.  Any element may be inserted/updated or
-- deleted.
newtype PatchDMap k v = PatchDMap (DMap k (ComposeMaybe v))

deriving instance GCompare k => Semigroup (PatchDMap k v)

deriving instance GCompare k => Monoid (PatchDMap k v)

instance GCompare k => Patch (PatchDMap k v) where
  type PatchTarget (PatchDMap k v) = DMap k v
  apply (PatchDMap diff) old = Just $! insertions `DMap.union` (old `DMap.difference` deletions) --TODO: return Nothing sometimes --Note: the strict application here is critical to ensuring that incremental merges don't hold onto all their prerequisite events forever; can we make this more robust?
    where insertions = DMap.mapMaybeWithKey (const $ getComposeMaybe) diff
          deletions = DMap.mapMaybeWithKey (const $ nothingToJust . getComposeMaybe) diff
          nothingToJust = \case
            Nothing -> Just $ Constant ()
            Just _ -> Nothing

-- | A set of changes to a 'Map'.  Any element may be inserted/updated or
-- deleted.
newtype PatchMap k v = PatchMap (Map k (Maybe v))

instance Ord k => Patch (PatchMap k v) where
  type PatchTarget (PatchMap k v) = Map k v
  apply (PatchMap p) old = Just $! insertions `Map.union` (old `Map.difference` deletions) --TODO: return Nothing sometimes --Note: the strict application here is critical to ensuring that incremental merges don't hold onto all their prerequisite events forever; can we make this more robust?
    where insertions = Map.mapMaybeWithKey (const id) p
          deletions = Map.mapMaybeWithKey (const nothingToJust) p
          nothingToJust = \case
            Nothing -> Just ()
            Just _ -> Nothing

instance Ord k => Semigroup (PatchMap k v) where
  PatchMap a <> PatchMap b = PatchMap $ a `mappend` b --TODO: Add a semigroup instance for Map
  -- PatchMap is idempotent, so stimes n is id for every n
#if MIN_VERSION_semigroups(0,17,0)
  stimes = stimesIdempotentMonoid
#else
  times1p n x = case compare n 0 of
    LT -> error "stimesIdempotentMonoid: negative multiplier"
    EQ -> mempty
    GT -> x
#endif

instance Ord k => Monoid (PatchMap k v) where
  mempty = PatchMap mempty
  mappend = (<>)

---- Patches based on commutative groups

-- | A 'Group' is a 'Monoid' where every element has an inverse.
class (Semigroup q, Monoid q) => Group q where
  negateG :: q -> q
  (~~) :: q -> q -> q
  r ~~ s = r <> negateG s

-- | An 'Additive' 'Semigroup' is one where the multiplication is commutative
class Semigroup q => Additive q where

-- | The elements of an 'Additive' 'Semigroup' can be considered as patches of their own type.
newtype AdditivePatch p = AdditivePatch { unAdditivePatch :: p }

instance Additive p => Patch (AdditivePatch p) where
  type PatchTarget (AdditivePatch p) = p
  apply (AdditivePatch p) q = Just $ p <> q
