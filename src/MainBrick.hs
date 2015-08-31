{-# LANGUAGE LambdaCase, OverloadedStrings, RecordWildCards #-}

module Main where

import Brick
import Brick.Widgets.DeviceList
import Brick.Widgets.Border
import Graphics.Vty hiding (Event, nextEvent)
import qualified Graphics.Vty as Vty

import DBus.UDisks2.Simple

import qualified Data.Text.IO as T
import Data.Text (Text)
import System.Exit
import System.IO
import Control.Monad
import Control.Concurrent
import Control.Concurrent.Chan
import Data.Default

data AppState = AppState {
  devList :: List Device,
  message :: Text
}

data AppEvent = DBusEvent Event
              | VtyEvent Vty.Event

draw :: AppState -> [Widget]
draw (AppState dl msg) = [w]
  where w =     renderDeviceList dl
            <=> hBorder
            <=> txt msg

handler :: AppState -> AppEvent -> (EventM (Next AppState))
handler appState@AppState{..} e = case e of
  VtyEvent (EvKey (KChar 'q') []) -> halt appState
  VtyEvent e' ->
    handleEvent e' devList >>= continueWith . onList . const
  DBusEvent (DeviceAdded dev) ->
    continueWith $ onList (listAppend dev)
  DBusEvent (DeviceRemoved dev) ->
    continueWith $ onList (listRemoveEq dev)
  DBusEvent (DeviceChanged old new) ->
    continueWith $ onList (listSwap old new)

  where continueWith :: (AppState -> AppState) -> EventM (Next AppState)
        continueWith f = return (f appState) >>= continue

theme :: AttrMap
theme = attrMap defAttr
  [ (listSelectedAttr, defAttr `withBackColor` brightBlack) ]

main :: IO ()
main = do
  (con,devs) <- connect >>= \case
    Left err -> do
      T.hPutStrLn stderr err
      exitWith (ExitFailure 1)
    Right x -> return x

  let devList = listMoveTo 0 $ newDeviceList "devices" devs
      app = App
            { appDraw = draw
            , appChooseCursor = neverShowCursor
            , appHandleEvent = handler
            , appStartEvent = return
            , appAttrMap = const theme
            , appLiftVtyEvent = VtyEvent
            }

  eventChan <- newChan

  forkIO $ eventThread con eventChan

  void $ customMain (mkVty def) eventChan app $
    AppState devList "Welcome"

eventThread :: Connection -> Chan AppEvent -> IO ()
eventThread con chan = forever $ do
  ev <- nextEvent con
  writeChan chan (DBusEvent ev)

-- not onLisp!
onList :: (List Device -> List Device) -> AppState -> AppState
onList f appState = appState { devList = f (devList appState)}
