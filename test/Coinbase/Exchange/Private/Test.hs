{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}

module Coinbase.Exchange.Private.Test
    ( tests
    , giveAwayOrder
    , run_placeOrder
    ) where

import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Concurrent

import           Data.IORef
import           Data.Maybe
import           Data.List
import           Data.Time
import           Data.Scientific
import           Data.UUID

import           System.Random

import           Test.Tasty
import           Test.Tasty.HUnit

import           Coinbase.Exchange.Private
import           Coinbase.Exchange.Types
import           Coinbase.Exchange.Types.Core
import           Coinbase.Exchange.Types.Private

import           Network.HTTP.Client.TLS
import           Network.HTTP.Conduit
import           System.Environment
import qualified Data.ByteString.Char8             as CBS

deriving instance Eq Order

-- NOTE: [Fills in Sandbox]
--
-- Orders don't seem to execute in the sandboxed environment provided by coinbase.
-- This means that we never get any fills. So, we can't test that API in the sandbox.
--


tests :: ExchangeConf -> TestTree
tests conf = testGroup "Private"
        [ testCase "getAccountList"     (do as <- run_getAccountList conf
                                            case as of
                                                [] -> error "Received empty list of accounts"
                                                _  -> return ()
                                        )

        , testCase "getUSDAccount"      (do as <- run_getAccountList conf
                                            let usdAccount = findUSDAccount as
                                            ac <- run_getAccount conf (accId usdAccount)
                                            assertEqual "accounts match" usdAccount ac
                                        )

        ,testCase "getUSDAccountLedger" (do as <- run_getAccountList conf
                                            let usdAccount = findUSDAccount as
                                            es <- run_getAccountLedger conf (accId usdAccount)
                                            case es of
                                                [] -> assertFailure "Received empty list of ledger entries" -- must not be empty to test parser
                                                _  -> return ()
                                        )

        , testCase "placeOrder"         (do o   <- creatNewLimitOrder
                                            oid <- run_placeOrder conf o             -- limit order
                                            oid'<- run_placeOrder conf giveAwayOrder -- market order
                                            return ()
                                        )

        , testCase "getOrderList"       (do run_getOrderList conf [Open, Pending] -- making sure this request is well formed
                                            os <- run_getOrderList conf []
                                            case os of
                                                [] -> assertFailure "Received empty order list"
                                                _  -> return ()
                                        )

        , testCase "getOrder"           (do no  <- creatNewLimitOrder
                                            oid <- run_placeOrder conf no
                                            o   <- run_getOrder conf oid
                                            assertEqual "order price"    (noPrice no) (orderPrice o)
                                            assertEqual "order size"     (noSize  no) (orderSize  o)
                                            assertEqual "order side"     (noSide  no) (orderSide  o)
                                            assertEqual "order product"  (noProductId no) (orderProductId o)
                                        )
        , testCase "cancelOrder"        (do no  <- creatNewLimitOrder
                                            oid <- run_placeOrder  conf no
                                            os  <- run_getOrderList conf [Open, Pending]
                                            run_cancelOrder conf oid
                                            os' <- run_getOrderList conf [Open, Pending]
                                            case os \\ os' of
                                                            [o] -> do
                                                                    assertEqual "order price"    (noPrice no) (orderPrice o)
                                                                    assertEqual "order size"     (noSize  no) (orderSize  o)
                                                                    assertEqual "order side"     (noSide  no) (orderSide  o)
                                                                    assertEqual "order product"  (noProductId no) (orderProductId o)

                                                            [] -> assertFailure "order not canceled"
                                                            _  -> assertFailure "more than one order canceled"
                                        )

        -- See NOTE: [Fills in Sandbox]
        , testCase "getFills"           (case apiType conf of
                                            Sandbox -> assertFailure "Running in Sanboxed environment. ** Cannot run getFills tests **"
                                            Live -> do oid <- run_placeOrder conf giveAwayOrder
                                                       fs <- run_getFills conf (Just oid) Nothing
                                                       case fs of
                                                           [] -> assertFailure "No fills found for an order that should execute immediately"
                                                           _  -> return ()
                                        )


        -------------------------- BTC TRANSFER TESTS --------------------------

        , testCase "get Coinbase (non-exchange) Accounts" $ do

            mgr     <- newManager tlsManagerSettings
            tKey    <- liftM CBS.pack $ getEnv "COINBASE_KEY_REAL"
            tSecret <- liftM CBS.pack $ getEnv "COINBASE_SECRET_REAL"
            let liveOrSandBox  = apiType conf
                conf2 = case mkToken tKey tSecret "" of
                    Right tok -> ExchangeConf mgr (Just tok) liveOrSandBox
                    Left   er -> error $ show er

            accounts <- run_getRealCoinbaseAccountList conf2
            putStrLn $ "COINBASE ACCOUNTS: " ++ accounts

        -----------------------------------------
        -- This test cause a "403 Forbiden" error when run in the Sanbox. I'm not sure that can be fixed on my end.
        -- FIX ME! This fails if we try to transfer small amounts (e.g. 0.01 as that is `show`n as "1.0e-2" and does not pass validation).
        , testCase "Transfer BTCs to Coinbase" $
            case apiType conf of
                Sandbox -> assertFailure "Running in Sanboxes environment. ** This test always fails - Is it not implemented by Coinbase? **"
                Live -> do
                    btcAccount <- getEnv "COINBASE_BTC_ACCOUNT_REAL"
                    let transfer = Withdraw
                            { trAmount            = 0.1
                            , trCoinbaseAccountId = CoinbaseAccountId $ fromJust $ fromString btcAccount}
                    run_sendToCoinbase conf transfer
                    return ()

        -- -----------------------------------------
        -- This test cause a "403 Forbiden" error when run in the Sanbox. I'm not sure that can be fixed on my end.
        -- FIX ME! This fails if we try to transfer small amounts (e.g. 0.01 as that is `show`n as "1.0e-2" and does not pass validation).
        , testCase "deposit BTCs from Coinbase" $
            case apiType conf of
                Sandbox -> assertFailure "Running in Sanboxes environment. ** This test always fails - Is it not implemented by Coinbase? **"
                Live -> do
                    btcAccount <- getEnv "COINBASE_BTC_ACCOUNT_REAL"
                    let transfer = Deposit
                            { trAmount            = 0.1  -- There must be this many BTCs there for this to work!
                            , trCoinbaseAccountId = CoinbaseAccountId $ fromJust $ fromString btcAccount}
                    run_sendToCoinbase conf transfer
                    return ()

        ---------------------------------------------
        , testCase "get Coinbase (non-exchange) BTC account info" $ do

            mgr     <- newManager tlsManagerSettings
            tKey    <- liftM CBS.pack $ getEnv "COINBASE_KEY_REAL"
            tSecret <- liftM CBS.pack $ getEnv "COINBASE_SECRET_REAL"
            realCoinbaseAccount <- getEnv "COINBASE_BTC_ACCOUNT_REAL"
            let liveOrSandBox  = apiType conf
                conf2 = case mkToken tKey tSecret "" of
                    Right tok -> ExchangeConf mgr (Just tok) liveOrSandBox
                    Left   er -> error $ show er

            info <- run_getPrimaryCoinbaseAccountInfo conf2
            putStrLn $ "COINBASE ACCOUNT INFO: " ++ show info

        -----------------------------------------
        -- CAREFULL ON LIVE ENVIRONMENT!!! TRANSFERS ARE IRREVERSIBLE!!!
        , testCase "send bitcoins from Coinbase Exchange (non-exchange) to remote wallet" $ do
        -- CAREFULL ON LIVE ENVIRONMENT!!! TRANSFERS ARE IRREVERSIBLE!!!
            mgr     <- newManager tlsManagerSettings
            tKey    <- liftM CBS.pack $ getEnv "COINBASE_KEY_REAL"
            tSecret <- liftM CBS.pack $ getEnv "COINBASE_SECRET_REAL"
            btcAccount <- getEnv "COINBASE_BTC_ACCOUNT_REAL"

            let liveOrSandBox  = apiType conf
                conf2 = case mkToken tKey tSecret "" of
                    Right tok -> ExchangeConf mgr (Just tok) liveOrSandBox
                    Left   er -> error $ show er

                remittance = SendBitcoin
                    { sendAmount    = 0.10
                    , bitcoinWallet = Wallet "1AwqxwJ4bVbCZDvVx5qBP5JDuaucfhxncq" -- mercado wallet
                    }

            transf <- run_sendBitcoins conf2 (CoinbaseAccountId $ fromJust $ fromString btcAccount) remittance
            return ()

        --------------------------------------------------------------------------------
        -- This test puts the previous 2 together;
        -- CAREFULL ON LIVE ENVIRONMENT!!! TRANSFERS ARE IRREVERSIBLE!!!
        , testCase "Transfer BTCs to Mercado" $
        -- CAREFULL ON LIVE ENVIRONMENT!!! TRANSFERS ARE IRREVERSIBLE!!!
            case apiType conf of
                Sandbox -> assertFailure "Running in Sanboxes environment. ** This test always fails - Is it not implemented by Coinbase? **"
                Live    -> do
                    mgr     <- newManager tlsManagerSettings
                    tKey    <- liftM CBS.pack $ getEnv "COINBASE_KEY_REAL"
                    tSecret <- liftM CBS.pack $ getEnv "COINBASE_SECRET_REAL"
                    btcAccount <- getEnv "COINBASE_BTC_ACCOUNT_REAL"

                    let conf2 = case mkToken tKey tSecret "" of
                            Right tok -> ExchangeConf mgr (Just tok) Live
                            Left   er -> error $ show er

                        transfer = Withdraw
                            { trAmount            = 0.1
                            , trCoinbaseAccountId = CoinbaseAccountId $ fromJust $ fromString btcAccount}

                        remittance = SendBitcoin
                            { sendAmount    = 0.1
                            , bitcoinWallet = undefined 
                            }

                    trsId <- run_sendToCoinbase conf transfer
                    threadDelay (1*1000*1000) -- This 1 second value is arbitrary, but Coinbase apparenty requires a small delay.
                    transf <- run_sendBitcoins conf2 (CoinbaseAccountId $ fromJust $ fromString btcAccount) remittance
                    return ()
        --------------------------------------------------------------------------------

        ]

-----------------------------------------------
giveAwayOrder :: NewOrder
giveAwayOrder = NewMarketOrder
    -- CAREFUL CHANGING THESE VALUES IF YOU PERFORM TESTING IN THE LIVE ENVIRONMENT. YOU MAY LOSE MONEY.
    { noProductId = "BTC-USD"
    , noSide      = Sell
    , noSelfTrade = DecrementAndCancel
    , noClientOid = Just $ ClientOrderId $ fromJust $ fromString "c2cc10e1-57d6-4b6f-9899-deadbeef2d8c"
    , noSizeAndOrFunds = Right (Just 0.01, 5) -- at most 1 BTC cent or 5 dollars per test
    }

creatNewLimitOrder :: IO NewOrder
creatNewLimitOrder = do
    -- can't be deterministic because exchange is stateful
    -- running a test twice with same random input may produce different results
    sz <- randomRIO (0,9999)
    -- CAREFUL CHANGING THESE VALUES IF YOU PERFORM TESTING IN THE LIVE ENVIRONMENT. YOU MAY LOOSE MONEY.
    return NewLimitOrder
        { noSize      = 0.01 + Size (CoinScientific $ fromInteger sz / 1000000 )
        , noPrice     = 10
        , noProductId = "BTC-USD"
        , noSide      = Buy
        , noSelfTrade = DecrementAndCancel
        , noClientOid = Just $ ClientOrderId $ fromJust $ fromString "c2cc10e1-57d6-4b6f-9899-111122223d8c"
        , noPostOnly  = False
        , noTimeInForce = GoodTillCanceled
        , noCancelAfter = Nothing
        }


findUSDAccount :: [Account] -> Account
findUSDAccount as = case filter (\a -> accCurrency a == CurrencyId "USD") as of
                        [a] -> a
                        []  -> error "no USD denominated account found"
                        _   -> error "more than one account denominated in USD found"

-----------------------------------------------
onSuccess :: ExchangeConf -> Exchange a -> String -> IO a
onSuccess conf apicall errorstring = do
        r <- liftIO $ runExchange conf apicall
        case r of
            Left  e -> print e >> error errorstring
            Right a -> return a

run_getAccountList :: ExchangeConf -> IO [Account]
run_getAccountList conf = onSuccess conf getAccountList "Failed to get account list"

run_getAccount :: ExchangeConf -> AccountId -> IO Account
run_getAccount conf acID = onSuccess conf (getAccount acID) "Failed to get account info"

run_getAccountLedger :: ExchangeConf -> AccountId -> IO [Entry]
run_getAccountLedger conf acID = onSuccess conf (getAccountLedger acID) "Failed to get account ledger"

run_placeOrder :: ExchangeConf -> NewOrder -> IO OrderId
run_placeOrder conf o = onSuccess conf (createOrder o) "Failed to create order"

run_getOrder :: ExchangeConf -> OrderId -> IO Order
run_getOrder conf oid = onSuccess conf (getOrder oid) "Failed to get order info"

run_getOrderList :: ExchangeConf -> [OrderStatus] -> IO [Order]
run_getOrderList conf ss = onSuccess conf (getOrderList ss) "Failed to get order list"

run_cancelOrder :: ExchangeConf -> OrderId -> IO ()
run_cancelOrder conf oid = onSuccess conf (cancelOrder oid) "Failed to cancel order"

run_getFills :: ExchangeConf -> Maybe OrderId -> Maybe ProductId -> IO [Fill]
run_getFills conf moid mpid = onSuccess conf (getFills moid mpid) "Failed to get fills"

-----------
-- FIX ME! This fails if we try to transfer amounts smaller than 0.1 BTC
-- (e.g. 0.01 as that is `shown` as "1.0e-2" and does not pass validation).
-- The proper way to fix it is to change the ToJSON instance of CoinScientific,
-- but I'm not messing with that at this point as I believe volumes should not
-- be expressed in terms of CoinScientific, but in `Volume`. This problem will
-- also be fixed by that change.

run_sendToCoinbase :: ExchangeConf -> TransferToCoinbase -> IO TransferId
run_sendToCoinbase conf transf = fmap trId $ onSuccess conf (createTransfer transf) "Failed to transfer to/from main coinbase account"

run_sendBitcoins :: ExchangeConf -> CoinbaseAccountId -> BTCTransferReq -> IO BTCTransferResponse
run_sendBitcoins conf acc req = onSuccess conf (sendBitcoins acc req) "Failed to send bitcoins to Wallet"

run_getRealCoinbaseAccountList :: ExchangeConf -> IO String
run_getRealCoinbaseAccountList conf = onSuccess conf getRealCoinbaseAccountList "Failed to get account list"

run_getPrimaryCoinbaseAccountInfo :: ExchangeConf -> IO CoinbaseAccount
run_getPrimaryCoinbaseAccountInfo conf = onSuccess conf getPrimaryCoinbaseAccountInfo "Failed to primary account info"
