{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Product (spec) where

import Data.Proxy
import GHC.Generics
import OCaml.Export
import Test.Hspec
import Util

testProduct = testOCamlType Product

spec :: Spec
spec = do
  describe "Product Types" $ do
    testProduct person "Person"
    testProduct company "Company"
    testProduct card "Card"
    testProduct oneTypeParameter "OneTypeParameter"
    testProduct twoTypeParameters "TwoTypeParameters"
    testProduct three "ThreeTypeParameters"
    testProduct subTypeParameter "SubTypeParameter"


data Person = Person
  { id :: Int
  , name :: Maybe String
  } deriving (Show, Eq, Generic, OCamlType)

data Company = Company
  { address   :: String
  , employees :: [Person]
  } deriving (Show, Eq, Generic, OCamlType)

data Suit
  = Clubs
  | Diamonds
  | Hearts
  | Spades
  deriving (Eq,Show,Generic,OCamlType)

data Card =
  Card
    { cardSuit  :: Suit
    , cardValue :: Int
    } deriving (Eq,Show,Generic,OCamlType)

data OneTypeParameter a =
  OneTypeParameter
    { otpId :: Int
    , otpFirst :: a
    } deriving (Eq,Show,Generic,OCamlType)

data TwoTypeParameters a b =
  TwoTypeParameters
    { ttpId :: Int
    , ttpFirst :: a
    , ttpSecond :: b
    } deriving (Eq,Show,Generic,OCamlType)

data Three a b c =
  Three
    { threeId :: Int
    , threeFirst :: a
    , threeSecond :: b
    , threeThird :: c
    , threeString :: String
    } deriving (Eq,Show,Generic,OCamlType)

data SubTypeParameter a =
  SubTypeParameter
    { as :: [a]
    } deriving (Eq,Show,Generic,OCamlType)

person :: OCamlFile
person =
  OCamlFile
    "Person"
    [ toOCamlTypeSource (Proxy :: Proxy Person)
    , toOCamlEncoderSource (Proxy :: Proxy Person)
    ]

company :: OCamlFile
company =
  OCamlFile
    "Company"
    [ toOCamlTypeSource (Proxy :: Proxy Person)
    , toOCamlEncoderSource (Proxy :: Proxy Person)
    , toOCamlTypeSource (Proxy :: Proxy Company)
    , toOCamlEncoderSource (Proxy :: Proxy Company)
    ]

card :: OCamlFile
card =
  OCamlFile
    "Card"
    [ toOCamlTypeSource (Proxy :: Proxy Suit)
    , toOCamlEncoderSource (Proxy :: Proxy Suit)
    , toOCamlTypeSource (Proxy :: Proxy Card)
    , toOCamlEncoderSource (Proxy :: Proxy Card)
    ]

oneTypeParameter :: OCamlFile
oneTypeParameter =
  OCamlFile
    "OneTypeParameter"
    [ toOCamlTypeSource (Proxy :: Proxy (OneTypeParameter TypeParameterRef0))
    , toOCamlEncoderSource (Proxy :: Proxy (OneTypeParameter TypeParameterRef0))
    ]

twoTypeParameters :: OCamlFile
twoTypeParameters =
  OCamlFile
    "TwoTypeParameters"
    [ toOCamlTypeSource (Proxy :: Proxy (TwoTypeParameters TypeParameterRef0 TypeParameterRef1))
    , toOCamlEncoderSource (Proxy :: Proxy (TwoTypeParameters TypeParameterRef0 TypeParameterRef1))
    ]

three :: OCamlFile
three =
  OCamlFile
    "ThreeTypeParameters"
    [ toOCamlTypeSource (Proxy :: Proxy (Three TypeParameterRef0 TypeParameterRef1 TypeParameterRef2))
    , toOCamlEncoderSource (Proxy :: Proxy (Three TypeParameterRef0 TypeParameterRef1 TypeParameterRef2))
    ]

subTypeParameter :: OCamlFile
subTypeParameter =
  OCamlFile
    "SubTypeParameter"
    [ toOCamlTypeSource (Proxy :: Proxy (SubTypeParameter TypeParameterRef0))
    , toOCamlEncoderSource (Proxy :: Proxy (SubTypeParameter TypeParameterRef0))
    ]
