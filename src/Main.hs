{-# LANGUAGE LambdaCase, OverloadedStrings, RecordWildCards #-}

module Main where

import Brick
import Brick.Widgets.DeviceList
import Brick.Widgets.Border
import Brick.Widgets.Dialog
import Brick.Widgets.HelpMessage
import Graphics.Vty hiding (Event, nextEvent)
import qualified Graphics.Vty as Vty

import DBus.UDisks2.Simple

import qualified Data.Text.IO as T
import qualified Data.Text as T
import Data.Text (Text)
import System.Exit
import System.IO
import Control.Monad
import Control.Concurrent
import Control.Concurrent.Chan
import Data.Default
import Data.Monoid
import Control.Monad.IO.Class
import Data.Maybe

data AppState = AppState {
  devList :: List Device,
  message :: Text,
  shownHelp :: Maybe KeyBindings,
  connection :: Connection
}

data AppEvent = DBusEvent Event
              | VtyEvent Vty.Event

helpMsg :: KeyBindings
helpMsg = KeyBindings
  [ ("General",
     [ ("q", "Quit")
     , ("Esc", "Close dialog")
     ])
  , ("Movement",
     [ ("j, Down", "Select next device")
     , ("k, Up", "Select previous device")
     , ("g, Home", "Select first device")
     , ("G, End", "Select last device")
     ])
  , ("Device operations",
     [ ("RET", "Mount or unmount device")])]

draw :: AppState -> [Widget]
draw (AppState dl msg dia _) = maybeToList dia' ++ [w]
  where w =     renderDeviceList dl
            <=> hBorder
            <=> txt msg

        dia' = help <$> dia

handler :: AppState -> AppEvent -> EventM (Next AppState)
handler appState@AppState{..} e = case e of
  VtyEvent e'@(EvKey _ _) ->
    handleKey e' (clearMessage appState) -- clear message on every keystroke
  VtyEvent _ -> continue appState
  DBusEvent (DeviceAdded dev) ->
    continueWith $ onList (listAppend dev)
  DBusEvent (DeviceRemoved dev) ->
    continueWith $ onList (listRemoveEq dev)
  DBusEvent (DeviceChanged old new) ->
    continueWith $ onList (listSwap old new)

  where continueWith :: (AppState -> AppState) -> EventM (Next AppState)
        continueWith f = continue (f appState)

        handleKey (EvKey (KChar 'q') []) as = halt as
        handleKey (EvKey (KChar '?') []) as = do
          resetHelpWidget -- scroll to the beginning
          continue (showHelp as)
        handleKey e as = case shownHelp of
          Nothing -> handleListKey e as
          Just b  -> handleDialogKey b e as

        handleListKey (EvKey KEnter []) as =
          liftIO (mountUnmount as) >>= continue
        handleListKey e as = do
          lst' <- handleHJKLEvent e devList
          continue $ as { devList = lst' }

        handleDialogKey _ (EvKey KEsc []) as = continue (hideHelp as)
        handleDialogKey b e as = void (handleEvent e b) >> continue as

theme :: AttrMap
theme = attrMap defAttr
  [ (listSelectedAttr, defAttr `withBackColor` brightBlack)
  , (helpAttr <> "title", fg green)
  ]

main :: IO ()
main = do
  let config = ConConfig { configIncludeInternal = False }

  (con,devs) <- connect config >>= \case
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
    AppState devList "Welcome! Press '?' to get help." Nothing con

eventThread :: Connection -> Chan AppEvent -> IO ()
eventThread con chan = forever $ do
  ev <- nextEvent con
  writeChan chan (DBusEvent ev)

mountUnmount :: AppState -> IO AppState
mountUnmount as@AppState{..} = case listSelectedElement devList of
  Nothing -> return $ showMessage as "No device selected"
  Just (_, dev)
    | devMounted dev  -> unmount connection dev >>= \case
        Left err -> return $ showMessage as $ "error: " <> err
        Right () -> return $ showMessage as "Device unmounted"
    | otherwise       -> mount connection dev >>= \case
        Left err -> return $ showMessage as $ "error: " <> err
        Right mp -> return $ showMessage as $ "Device mounted at " <> mp

showMessage :: AppState -> Text -> AppState
showMessage as msg = as { message = msg }

clearMessage :: AppState -> AppState
clearMessage = flip showMessage " "

showHelp :: AppState -> AppState
showHelp as = as { shownHelp = Just bindings }
  where bindings = helpMsg

hideHelp :: AppState -> AppState
hideHelp as = as { shownHelp = Nothing }

-- not onLisp!
onList :: (List Device -> List Device) -> AppState -> AppState
onList f appState = appState { devList = f (devList appState)}
