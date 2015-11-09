{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE RankNTypes                 #-}

-- | Example usage:
--
-- > {-# LANGUAGE OverloadedStrings #-}
-- > 
-- > import Control.Applicative.Updatable
-- > 
-- > main :: IO ()
-- > main = textUI "Example program" (\control ->
-- >     let combine a b c d = display (a, b + c, d)
-- > 
-- >     in combine <$> checkBox   control "a"
-- >                <*> spinButton control "b" 1
-- >                <*> spinButton control "c" 0.1
-- >                <*> entry      control "d" )

module Control.Applicative.Updatable (
    -- * Types
      Updatable
    , Control
    , textUI

    -- * Controls
    , checkBox
    , spinButton
    , entry
    , radioButton

    -- * Utilities
    , display
    ) where

import Control.Applicative
import Control.Concurrent.STM (STM)
import Control.Foldl (Fold(..))
import Control.Monad.IO.Class (liftIO)
import Data.String (IsString(..))
import Data.Text (Text)
import Lens.Micro (_Left, _Right)
import Graphics.UI.Gtk (AttrOp((:=)))

import qualified Control.Concurrent.STM   as STM
import qualified Control.Concurrent.Async as Async
import qualified Control.Foldl            as Fold
import qualified Data.Text                as Text
import qualified Graphics.UI.Gtk          as Gtk

-- | An updatable input value
data Updatable a = forall e . Updatable (IO (STM e, Fold e a))

instance Functor Updatable where
    fmap f (Updatable m) = Updatable (fmap (fmap (fmap f)) m)

instance Applicative Updatable where
    pure a = Updatable (pure (empty, pure a))

    Updatable mF <*> Updatable mX = Updatable (liftA2 helper mF mX)
      where
        helper (inputF, foldF) (inputX, foldX) = (input, fold )
          where
            input = fmap Left inputF <|> fmap Right inputX

            fold = Fold.handles _Left foldF <*> Fold.handles _Right foldX

instance Monoid a => Monoid (Updatable a) where
    mempty = pure mempty

    mappend = liftA2 mappend

instance IsString a => IsString (Updatable a) where
    fromString str = pure (fromString str)

instance Num a => Num (Updatable a) where
    fromInteger = pure . fromInteger

    negate = fmap negate
    abs    = fmap abs
    signum = fmap signum

    (+) = liftA2 (+)
    (*) = liftA2 (*)
    (-) = liftA2 (-)

instance Fractional a => Fractional (Updatable a) where
    fromRational = pure . fromRational

    recip = fmap recip

    (/) = liftA2 (/)

instance Floating a => Floating (Updatable a) where
    pi = pure pi

    exp   = fmap exp
    sqrt  = fmap sqrt
    log   = fmap log
    sin   = fmap sin
    tan   = fmap tan
    cos   = fmap cos
    asin  = fmap sin
    atan  = fmap atan
    acos  = fmap acos
    sinh  = fmap sinh
    tanh  = fmap tanh
    cosh  = fmap cosh
    asinh = fmap asinh
    atanh = fmap atanh
    acosh = fmap acosh

    (**)    = liftA2 (**)
    logBase = liftA2 logBase

-- | Use a `Control` to obtain updatable input `Updatable`s
data Control = Control
    { _checkBox    :: Text -> Updatable Bool
    , _spinButton  :: Text -> Double -> Updatable Double
    , _entry       :: Text -> Updatable Text
    , _radioButton :: forall a . Show a => Text -> a -> [a] -> Updatable a
    }

-- | Build a `Text`-based user interface
textUI
    :: Text
    -- ^ Window title
    -> (Control -> Updatable Text)
    -- ^ Program logic
    -> IO ()
textUI title k = do
    _ <- Gtk.initGUI

    window <- Gtk.windowNew
    Gtk.set window
        [ Gtk.containerBorderWidth := 5
        ]

    textView   <- Gtk.textViewNew
    textBuffer <- Gtk.get textView Gtk.textViewBuffer
    Gtk.set textView
        [ Gtk.textViewEditable      := False
        , Gtk.textViewCursorVisible := False
        ]

    hAdjust <- Gtk.textViewGetHadjustment textView
    vAdjust <- Gtk.textViewGetVadjustment textView
    scrolledWindow <- Gtk.scrolledWindowNew (Just hAdjust) (Just vAdjust)
    Gtk.set scrolledWindow
        [ Gtk.containerChild           := textView
        , Gtk.scrolledWindowShadowType := Gtk.ShadowIn
        ]

    vBox <- Gtk.vBoxNew False 5

    hBox <- Gtk.hBoxNew False 5
    Gtk.boxPackStart hBox vBox           Gtk.PackNatural 0
    Gtk.boxPackStart hBox scrolledWindow Gtk.PackGrow    0

    Gtk.set window
        [ Gtk.windowTitle         := title
        , Gtk.containerChild      := hBox
        , Gtk.windowDefaultWidth  := 600
        , Gtk.windowDefaultHeight := 400
        ]

    let __spinButton :: Text -> Double -> Updatable Double
        __spinButton label stepX = Updatable (do
            tmvar      <- STM.newEmptyTMVarIO
            let minX = fromIntegral (minBound :: Int)
            let maxX = fromIntegral (maxBound :: Int)
            spinButton_ <- Gtk.spinButtonNewWithRange minX maxX stepX
            Gtk.set spinButton_
                [ Gtk.spinButtonValue    := 0
                ]
            _  <- Gtk.onValueSpinned spinButton_ (do
                n <- Gtk.get spinButton_ Gtk.spinButtonValue
                STM.atomically (STM.putTMVar tmvar n) )

            frame <- Gtk.frameNew
            Gtk.set frame
                [ Gtk.containerChild := spinButton_
                , Gtk.frameLabel     := label
                ]

            Gtk.boxPackStart vBox frame Gtk.PackNatural 0
            Gtk.widgetShowAll vBox
            return (STM.takeTMVar tmvar, Fold.lastDef 0) )

    let __checkBox :: Text -> Updatable Bool
        __checkBox label = Updatable (do
            checkButton <- Gtk.checkButtonNewWithLabel label

            tmvar <- STM.newEmptyTMVarIO
            _     <- Gtk.on checkButton Gtk.toggled (do
                pressed <- Gtk.get checkButton Gtk.toggleButtonActive
                STM.atomically (STM.putTMVar tmvar pressed) )

            Gtk.boxPackStart vBox checkButton Gtk.PackNatural 0
            Gtk.widgetShowAll vBox
            return (STM.takeTMVar tmvar, Fold.lastDef False) )

    let __entry :: Text -> Updatable Text
        __entry label = Updatable (do
            entry_ <- Gtk.entryNew

            frame <- Gtk.frameNew
            Gtk.set frame
                [ Gtk.containerChild := entry_
                , Gtk.frameLabel     := label
                ]

            tmvar <- STM.newEmptyTMVarIO
            _     <- Gtk.on entry_ Gtk.editableChanged (do
                txt <- Gtk.get entry_ Gtk.entryText
                STM.atomically (STM.putTMVar tmvar txt) )

            Gtk.boxPackStart vBox frame Gtk.PackNatural 0
            Gtk.widgetShowAll frame
            return (STM.takeTMVar tmvar, Fold.lastDef Text.empty) )

    let __radioButton :: Show a => Text -> a -> [a] -> Updatable a
        __radioButton label x xs = Updatable (do
            tmvar <- STM.newEmptyTMVarIO

            vBoxRadio <- Gtk.vBoxNew False 5

            let makeButton f a = do
                    button <- f (show a)
                    Gtk.boxPackStart vBoxRadio button Gtk.PackNatural 0
                    _ <- Gtk.on button Gtk.toggled (do
                        mode <- Gtk.get button Gtk.toggleButtonMode
                        if mode
                            then STM.atomically (STM.putTMVar tmvar a)
                            else return () )
                    return button

            button <- makeButton Gtk.radioButtonNewWithLabel x
            mapM_ (makeButton (Gtk.radioButtonNewWithLabelFromWidget button)) xs

            frame <- Gtk.frameNew
            Gtk.set frame
                [ Gtk.containerChild := vBoxRadio
                , Gtk.frameLabel     := label
                ]
            Gtk.boxPackStart vBox frame Gtk.PackNatural 0
            Gtk.widgetShowAll frame
            return (STM.takeTMVar tmvar, Fold.lastDef x) )

    let control = Control
            { _checkBox    = __checkBox
            , _spinButton  = __spinButton
            , _entry       = __entry
            , _radioButton = __radioButton
            }

    doneTMVar <- STM.newEmptyTMVarIO

    let run :: Updatable Text -> IO ()
        run (Updatable m) = do
            (stm, Fold step begin done) <- Gtk.postGUISync m
            let loop x = do
                    let txt = done x
                    Gtk.postGUISync
                        (Gtk.set textBuffer [ Gtk.textBufferText := txt ])
                    let doneTransaction = do
                            STM.takeTMVar doneTMVar
                            return Nothing
                    me <- STM.atomically (doneTransaction <|> fmap pure stm)
                    case me of
                        Nothing -> return ()
                        Just e  -> loop (step x e)
            loop begin

    _ <- Gtk.on window Gtk.deleteEvent (liftIO (do
        STM.atomically (STM.putTMVar doneTMVar ())
        Gtk.mainQuit
        return False ))
    Gtk.widgetShowAll window
    Async.withAsync (run (k control)) (\a -> do
        Gtk.mainGUI
        Async.wait a )

-- | A check box that returns `True` if selected and `False` if unselected
checkBox
    :: Control
    -> Text
    -- ^ Label
    -> Updatable Bool
checkBox = _checkBox

-- | A `Double` spin button
spinButton
    :: Control
    -- ^
    -> Text
    -- ^ Label
    -> Double
    -- ^ Step size
    -> Updatable Double
spinButton = _spinButton

-- | A `Text` entry
entry
    :: Control
    -- ^
    -> Text
    -- ^ Label
    -> Updatable Text
entry = _entry

-- | A control that selects from one or more mutually exclusive values
radioButton
    :: Show a
    => Control
    -- ^
    -> Text
    -- ^ Label
    -> a
    -- ^ 1st value (Default selection)
    -> [a]
    -- ^ Remaining values
    -> Updatable a
radioButton = _radioButton

-- | Convert a `Show`able value to `Text`
display :: Show a => a -> Text
display = Text.pack . show