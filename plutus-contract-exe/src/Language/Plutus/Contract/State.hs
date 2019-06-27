{-# LANGUAGE DerivingStrategies    #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}
-- | A version of 'Language.Plutus.Contract.Contract' that
--   writes checkpoints
module Language.Plutus.Contract.State where

import           Control.Monad.Except
import           Control.Monad.Reader
import           Control.Monad.State
import           Control.Monad.Writer
import qualified Data.Aeson                         as Aeson
import qualified Data.Aeson.Types                   as Aeson
import           Data.Bifunctor                     (Bifunctor (..))
import           Data.Foldable                      (toList)
import qualified Data.Map                           as Map

import qualified Language.Plutus.Contract.Contract  as C
import           Language.Plutus.Contract.Event     as Event
import           Language.Plutus.Contract.Hooks     as Hooks
import           Language.Plutus.Contract.Record
import           Language.Plutus.Contract.RequestId

data StatefulContract a where
    CMap :: (a' -> a) -> StatefulContract  a' -> StatefulContract  a
    CAp :: StatefulContract  (a' -> a) -> StatefulContract  a' -> StatefulContract  a
    CBind :: StatefulContract  a' -> (a' -> StatefulContract  a) -> StatefulContract  a

    CContract :: C.ContractPrompt (Either Hooks) a -> StatefulContract  a
    CJSONCheckpoint :: (Aeson.FromJSON a, Aeson.ToJSON a) => StatefulContract  a -> StatefulContract  a

initialise
    :: (MonadState RequestId m)
    => StatefulContract a
    -> m (Either (OpenRecord RequestId Hooks) (ClosedRecord RequestId Hooks, a))
initialise = \case
    CMap f con -> fmap (fmap f) <$> initialise con
    CAp conL conR -> do
        l' <- initialise conL
        r' <- initialise conR
        case (l', r') of
            (Left l, Left r) -> pure $ Left (OpenBoth l r)
            (Right (l, _), Left r) -> pure $ Left (OpenRight l r)
            (Left l, Right (r, _)) -> pure $ Left (OpenLeft l r)
            (Right (l, f), Right (r, a)) -> pure $ Right (ClosedBin l r, f a)
    CBind c f -> do
        l <- initialise c
        case l of
            Left l' -> pure $ Left (OpenBind l')
            Right (l', a) -> do
                r <- initialise (f a)
                case r of
                    Left r' -> pure $ Left $ OpenRight l' r'
                    Right (r', b) -> pure $ Right (ClosedBin l' r', b)
    CContract con -> do
        (r, _) <- runReaderT (C.runContract' con) mempty
        case r of
            Nothing -> pure $ Left $ OpenLeaf mempty
            Just a -> pure $ Right (ClosedLeaf (FinalEvents mempty), a)
    CJSONCheckpoint con -> do
        r <- initialise con
        case r of
            Left _ -> pure r
            Right (_, a) -> pure $ Right (jsonLeaf a mempty, a)
        

checkpoint :: (Aeson.FromJSON a, Aeson.ToJSON a) => StatefulContract  a -> StatefulContract  a
checkpoint = CJSONCheckpoint

prtty :: StatefulContract  a -> String
prtty = \case
    CMap _ c -> "cmap (" ++ prtty c ++ ")"
    CAp l r -> "cap (" ++ prtty l ++ ") (" ++ prtty r ++ ")"
    CBind l _ -> "cbind (" ++ prtty l ++  ") f"
    CContract _ -> "ccontract"
    CJSONCheckpoint j -> "json(" ++ prtty j ++ ")"

instance Functor StatefulContract where
    fmap f = \case
        CMap f' c -> CMap (f . f') c
        CAp l r     -> CAp (fmap (fmap f) l) r
        CBind m f'  -> CBind m (fmap f . f')

        CContract con -> CContract (fmap f con)
        CJSONCheckpoint c -> CMap f (CJSONCheckpoint c)

-- lower
--     :: (forall a b m. (a -> b) -> m a -> m b)
--     -> (forall a b m. m (a -> b) -> m a -> m b)
--     -> (forall a b m. m a -> (a -> m b) -> m b)
--     -> (forall a'. (Aeson.FromJSON a', Aeson.ToJSON a') => m a' -> m a')
--     -> (forall a'. C.ContractPrompt (Either Hooks) a' -> m a')
--     -> StatefulContract a
--     -> m a
-- lower fmap_ ap_ bind_ fj fc = 
--     \case
--         CMap f c' -> fmap_ f (lower fmap_ ap_ bind_ fj fc c')
--         CAp l r -> ap_ (lower fmap_ ap_ bind_ fj fc l) (lower fmap_ ap_ bind_ fj fc r)
--         CBind a f -> bind_ (lower fmap_ ap_ bind_ fj fc a) (fmap_ (lower fmap_ ap_ bind_ fj fc) f)
--         CContract c' -> fc c'
--         CJSONCheckpoint c' -> fj (lower fmap_ ap_ bind_ fj fc c')


lowerM
    :: (Monad m)
    -- ^ What to do with map, ap, bind
    => (forall a'. (Aeson.FromJSON a', Aeson.ToJSON a') => m a' -> m a')
    -- ^ What to do with JSON checkpoints
    -> (forall a'. C.ContractPrompt (Either Hooks) a' -> m a')
    -- ^ What to do with the contracts
    -> StatefulContract a
    -> m a
lowerM fj fc = \case
    CMap f c' -> f <$> lowerM fj fc c'
    CAp l r -> lowerM fj fc l <*> lowerM fj fc r
    CBind c' f -> lowerM fj fc c' >>= fmap (lowerM fj fc) f
    CContract c' -> fc c'
    CJSONCheckpoint c' -> fj (lowerM fj fc c')

instance Applicative StatefulContract where
    pure = CContract . pure
    (<*>) = CAp

instance Monad StatefulContract where
    (>>=) = CBind

runConM
    :: ( MonadState RequestId m
       , MonadReader (Map.Map RequestId Event) m
       , MonadWriter Hooks m)
    => C.ContractPrompt (Either Hooks) a
    -> m (Maybe a)
runConM con = C.runContract' con >>= writer

runClosed
    :: ( MonadWriter Hooks m
       , MonadState RequestId m
       , MonadReader (Map.Map RequestId Event) m
       , MonadError String m)
    => StatefulContract  a
    -> ClosedRecord RequestId Hooks
    -> m a
runClosed con = \case
    ClosedLeaf (FinalEvents _) ->
        case con of
            CContract con' -> do
                r <- runConM con'
                case r of
                    Nothing -> throwError "ClosedLeaf, contract not finished"
                    Just  a -> pure a
            _ -> throwError "ClosedLeaf, expected CContract "
    ClosedLeaf (FinalJSON vl o) ->
        case con of
            CJSONCheckpoint _ ->
                case Aeson.parseEither Aeson.parseJSON vl of
                    Left e    -> throwError e
                    Right vl' -> writer (vl', o)
            _ -> throwError "Expected JSON checkpoint"
    ClosedBin l r ->
        case con of
            CMap f con' -> fmap f (runClosed con' (ClosedBin l r))
            CAp l' r'   -> runClosed l' l <*> runClosed r' l
            CBind l' f  -> runClosed l' l >>= flip runClosed r . f
            _           -> throwError "ClosedBin with wrong contract type"

runOpen
    :: ( MonadWriter Hooks m
       , MonadState RequestId m
       , MonadReader (Map.Map RequestId Event) m
       , MonadError String m)
    => StatefulContract  a
    -> OpenRecord RequestId Hooks
    -> m (Either (OpenRecord RequestId Hooks) (ClosedRecord RequestId Hooks, a))
runOpen con opr =
    case (con, opr) of
        (CMap f con', _) -> (fmap .fmap $ fmap f) (runOpen con' opr)
        (CAp l r, OpenLeft opr' cr) -> do
            lr <- runOpen l opr'
            rr <- runClosed r cr
            case lr of
                Left opr''     -> pure (Left (OpenLeft opr'' cr))
                Right (cr', a) -> pure (Right (ClosedBin cr' cr, a rr))
        (CAp l r, OpenRight cr opr') -> do
            lr <- runClosed l cr
            rr <- runOpen r opr'
            case rr of
                Left opr''     -> pure (Left (OpenRight cr opr''))
                Right (cr', a) -> pure (Right (ClosedBin cr cr', lr a))
        (CAp l r, OpenBoth orL orR) -> do
            lr <- runOpen l orL
            rr <- runOpen r orR
            case (lr, rr) of
                (Right (crL, a), Right (crR, b)) ->
                    pure (Right (ClosedBin crL crR, a b))
                (Right (crL, _), Left oR) ->
                    pure (Left (OpenRight crL oR))
                (Left oL, Right (cR, _)) ->
                    pure (Left (OpenLeft oL cR))
                (Left oL, Left oR) ->
                    pure (Left (OpenBoth oL oR))
        (CAp{}, OpenLeaf _) -> throwError "CAp OpenLeaf"

        (CBind c f, OpenBind bnd) -> do
            lr <- runOpen c bnd
            case lr of
                Left orL' -> pure (Left orL')
                Right (crL, a) -> do
                    let con' = f a
                    orR' <- initialise con'
                    case orR' of
                        Right (crrrr, a') -> pure (Right (ClosedBin crL crrrr, a'))
                        Left orrrr -> do
                            rr <- runOpen con' orrrr
                            case rr of
                                Left orR'' ->
                                    pure (Left (OpenRight crL orR''))
                                Right (crR, a') ->
                                    pure (Right (ClosedBin crL crR, a'))

        (CBind c f, OpenRight cr opr') -> do
            lr <- runClosed c cr
            rr <- runOpen (f lr) opr'
            case rr of
                Left opr''     -> pure (Left (OpenRight cr opr''))
                Right (cr', a) -> pure (Right (ClosedBin cr cr', a))
        (CBind{}, _) -> throwError $ "CBind " ++ show opr

        (CContract con', OpenLeaf is) -> do
                r <- runConM con'
                case r of
                    Just a  -> pure (Right (ClosedLeaf (FinalEvents is), a))
                    Nothing -> pure (Left (OpenLeaf is))
        (CContract{}, _) -> throwError $ "CContract non leaf " ++ show opr

        (CJSONCheckpoint con', opr') -> do
            (r, o) <- listen (runOpen con' opr')
            pure $ fmap (\(_, a) -> (jsonLeaf a o, a)) r
        _ -> throwError "runOpen"

updateRecord
    :: StatefulContract  a
    -> Map.Map RequestId Event
    -> Record RequestId Hooks
    -> Either String (Record RequestId Hooks, Hooks)
updateRecord con mp rc =
    case rc of
        Right cl -> fmap (first $ const $ Right cl) $ runExcept $ flip  evalStateT 0 $ runWriterT $ runReaderT (runClosed con cl) mp
        Left cl  -> fmap (first (fmap fst)) $ runExcept $ flip evalStateT 0 $ runWriterT $ runReaderT (runOpen con cl) mp
