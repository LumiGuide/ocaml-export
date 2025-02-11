{-|
Module      : OCaml.BuckleScript.Decode
Description : Make a JSON decoder for an OCamlDatatype that matches Generic aeson FromJSON
Copyright   : Plow Technologies, 2017
License     : BSD3
Maintainer  : mchaver@gmail.com
Stability   : experimental

-}

{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

module OCaml.BuckleScript.Decode
  ( toOCamlDecoderSourceWith
  , toOCamlDecoderInterfaceWith
  ) where

-- base
import Control.Monad.Reader
import qualified Data.List as L
import Data.Maybe (catMaybes)
import Data.Typeable
-- aeson
import qualified Data.Aeson.Types as Aeson (Options(..))
-- containers
import qualified Data.Map.Strict as Map
-- text
import Data.Text (Text)
import qualified Data.Text as T
-- wl-pprint
import Text.PrettyPrint.Leijen.Text
  (Doc, (<+>), (<$$>), comma, dquotes, empty, indent, int, line, parens)
-- ocaml-export
import OCaml.BuckleScript.Types hiding (getOCamlValues)
import OCaml.Internal.Common

-- | Convert a 'Proxy a' into OCaml type to decode JSON function source code with an interface file '.mli'.
toOCamlDecoderInterfaceWith :: forall a. OCamlType a => Options -> a -> T.Text
toOCamlDecoderInterfaceWith options a =
  case toOCamlType (Proxy :: Proxy a) of
    OCamlDatatype haskellTypeMetaData _ _ ->
      case Map.lookup haskellTypeMetaData (dependencies options) of
        Just ocamlTypeMetaData -> pprinter $ runReader (renderInterface (toOCamlType a)) (TypeMetaData (Just ocamlTypeMetaData) options)
        Nothing -> ""          
    _ -> pprinter $ runReader (renderInterface (toOCamlType a)) (TypeMetaData Nothing options)

-- | Convert a 'Proxy a' into OCaml type to decode JSON function source code without an interface file '.mli'.
toOCamlDecoderSourceWith :: forall a. OCamlType a => Options -> a -> T.Text
toOCamlDecoderSourceWith options a =
  case toOCamlType (Proxy :: Proxy a) of
    OCamlDatatype haskellTypeMetaData _ _ ->
      case Map.lookup haskellTypeMetaData (dependencies options) of
        Just ocamlTypeMetaData -> pprinter $ runReader (render (toOCamlType a)) (TypeMetaData (Just ocamlTypeMetaData) options)
        Nothing -> ""
    _ -> pprinter $ runReader (render (toOCamlType a)) (TypeMetaData Nothing options)

-- Internal

-- | Render OCamlDatatype into an OCaml declaration
class HasDecoder a where
  render :: a -> Reader TypeMetaData Doc

-- | Render OCamlPrimitive decoders and type parameters
class HasDecoderRef a where
  renderRef :: a -> Reader TypeMetaData Doc

-- | Render OCamlDataype into an OCaml interface
class HasDecoderInterface a where
  renderInterface :: a -> Reader TypeMetaData Doc

instance HasDecoderInterface OCamlDatatype where
  renderInterface datatype@(OCamlDatatype _ typeName constructor@(OCamlSumOfRecordConstructor _ (MultipleConstructors constructors))) = do
    fnName <- renderRef datatype
    let typeParameterInterfaces = linesBetween $ catMaybes (renderSumRecordInterface typeName . OCamlValueConstructor <$> constructors)
        (typeParameterEncoders, typeParameters) = renderTypeParameterVals constructor
    pure $ typeParameterInterfaces
      <$$> "val" <+> fnName <+> ":" <+> typeParameterEncoders <> "Js_json.t ->" <+> "(" <> typeParameters <> (stext . textLowercaseFirst $ typeName) <> ", string)" <+> "Belt.Result.t"
    

  renderInterface _datatype@(OCamlDatatype _ typeName constructors) = do
    -- fnName <- renderRef datatype
    let (typeParameterEncoders, typeParameters) = renderTypeParameterVals constructors
    pure $ "val" <+> "decode" <> (stext typeName) <+> ":" <+> typeParameterEncoders <> "Js_json.t ->" <+> "(" <> typeParameters <> (stext . textLowercaseFirst $ typeName) <> ", string)" <+> "Belt.Result.t"

  renderInterface _ = pure ""

instance HasDecoder OCamlDatatype where
  -- Sum with records
  render datatype@(OCamlDatatype _ typeName constructor@(OCamlSumOfRecordConstructor _ (MultipleConstructors constructors))) = do
    fnName <- renderRef datatype
    fnBody <- mapM renderSum (OCamlSumOfRecordConstructor typeName <$> constructors)
    typeParameterDeclarations <- linesBetween <$> catMaybes <$> sequence (renderSumRecord typeName . OCamlValueConstructor <$> constructors)
    ocamlInterface <- asks (includeOCamlInterface . userOptions)
    if ocamlInterface
      then do
       pure $ typeParameterDeclarations <$$>
         ("let" <+> fnName <+> "json =") <$$>
         (indent 2 ("match Aeson.Decode.(field \"tag\" string json) with" <$$> foldl1 (<$$>) fnBody <$$> fnFooter))
      else do
        let (typeParameterSignatures,typeParameters) = renderTypeParameters constructor
        pure $ typeParameterDeclarations <$$>
          ("let" <+> fnName <+> typeParameterSignatures <+> "(json : Js_json.t)" <+> typeParameters <> ":(" <> stext (textLowercaseFirst typeName) <> ", string) Belt.Result.t =") <$$>
          (indent 2 ("match Aeson.Decode.(field \"tag\" string json) with" <$$> foldl1 (<$$>) fnBody <$$> fnFooter))
    where
      fnFooter =
              "| err -> Belt.Result.Error (\"Unknown tag value found '\" ^ err ^ \"'.\")"
         <$$> "| exception Aeson.Decode.DecodeError message -> Belt.Result.Error message"

  -- special logic for single enumerators
  render datatype@(OCamlDatatype _ _typeName (OCamlEnumeratorConstructor [(EnumeratorConstructor name)])) = do
    fnName <- renderRef datatype
    
    pure $ "let" <+> fnName <+> "json =" <$$>
           indent 2 ("match (Aeson.Decode.(list int json)) with" <$$>
           "| _ -> Belt.Result.Ok" <+> stext name <$$>
           "| exception Aeson.Decode.DecodeError message -> Belt.Result.Error (\"" <> fnName <> ": expected a top-level empty JSON array. Got: \" ^ message)")

  render datatype@(OCamlDatatype _ name constructor@(OCamlEnumeratorConstructor constructors)) = do
    fnName <- renderRef datatype
    fnBody <- mapM render constructors
    ocamlInterface <- asks (includeOCamlInterface . userOptions)
    if ocamlInterface
      then do
        pure $ "let" <+> fnName <+> "json ="
          <$$> indent 2 ("match Js_json.decodeString json with"
          <$$> foldl1 (<$$>) fnBody <$$> fnFooter fnName)
      else do
        let (typeParameterSignatures,typeParameters) = renderTypeParameters constructor
            returnType =  "(" <> typeParameters <> (stext . textLowercaseFirst $ name) <> ", string) Belt.Result.t ="
        pure $ "let" <+> fnName <+> typeParameterSignatures <+>"(json : Js_json.t) :" <> returnType
          <$$> indent 2 ("match Js_json.decodeString json with"
          <$$> foldl1 (<$$>) fnBody <$$> fnFooter fnName)
    where
      fnFooter fnName
        =    "| Some err -> Belt.Result.Error (\"" <> fnName <> ": unknown enumeration '\" ^ err ^ \"'.\")"
        <$$> "| None -> Belt.Result.Error \"" <> fnName <> ": expected a top-level JSON string.\""
      
  render (OCamlDatatype _ typeName constructor) = do
    let fnName = "decode" <> (stext typeName)
    fnBody <- render constructor
    ocamlInterface <- asks (includeOCamlInterface . userOptions)
    if ocamlInterface
      then do
        let typeParameters = getTypeParameters constructor
            renderedTypeParameters = foldl (<>) "" $ stext <$> L.intersperse " " ((\t -> "decode" <> (textUppercaseFirst t)) <$> (L.sort typeParameters))
        pure $ "let" <+> fnName <+> renderedTypeParameters <+> "json" <+> "=" <$$> fnBody
      else do
        let (typeParameterSignatures,typeParameters) = renderTypeParameters constructor
            returnType = "(" <> typeParameters <> (stext . textLowercaseFirst $ typeName) <> ", string) Belt.Result.t ="
        pure $ "let" <+> fnName <+> typeParameterSignatures <+> "(json : Js_json.t) :" <> returnType <$$> fnBody

  render (OCamlPrimitive primitive) = renderRef primitive

instance HasDecoderRef OCamlDatatype where
  renderRef (OCamlDatatype typeRef typeName (OCamlValueConstructor (NamedConstructor _ (OCamlRefApp typRep values)))) = do
    let name = "decode" <> (stext typeName)
    dx <- renderRef values

    mOCamlTypeMetaData <- asks topLevelOCamlTypeMetaData 
    case mOCamlTypeMetaData of
      Nothing -> pure $ parens $ name <+> dx
      Just decOCamlTypeMetaData -> do
        ds <- asks (dependencies . userOptions)
        case Map.lookup (typeRepToHaskellTypeMetaData typRep) ds of
          Just parOCamlTypeMetaData -> do
            let prefix = stext $ mkModulePrefix decOCamlTypeMetaData parOCamlTypeMetaData
            pure $ parens $ prefix <> name <+> dx
          Nothing -> error ("OCaml.BuckleScript.Decode (HasDecoderRef OCamlDataType) expected to find dependency:\n\n" ++ show typeRef ++ "\n\nin\n\n" ++ show ds)
  
  -- this should only catch type parameters
  renderRef datatype@(OCamlDatatype typeRef name _) =
    if isTypeParameterRef datatype
    then
      pure $ parens ("fun a -> unwrapResult" <+> parens ("decode" <> (stext . textUppercaseFirst $ name) <+> "a"))
    else do
      mOCamlTypeMetaData <- asks topLevelOCamlTypeMetaData 
      case mOCamlTypeMetaData of
        Nothing -> pure $ "decode" <> (stext . textUppercaseFirst $ name)
        Just decOCamlTypeMetaData -> do
          ds <- asks (dependencies . userOptions)
          case Map.lookup typeRef ds of
            Just parOCamlTypeMetaData -> do
              let prefix = stext $ mkModulePrefix decOCamlTypeMetaData parOCamlTypeMetaData
              pure $ prefix <> "decode" <> (stext . textUppercaseFirst $ name)

            Nothing -> error ("OCaml.BuckleScript.Decode (HasDecoderRef OCamlDataType) expected to find dependency:\n\n" ++ show typeRef ++ "\n\nin\n\n" ++ show ds)

  renderRef (OCamlPrimitive primitive) = renderRef primitive

instance HasDecoder OCamlConstructor where
  render (OCamlValueConstructor (NamedConstructor name value@(OCamlRefApp _ _))) = do
    decoder <- render value
    let constructorParams = constructorParameters 0 value
    v <- mk name 0 $ (Just <$> flattenOCamlValue value) ++ [Nothing]
    pure $
      if length constructorParams > 1
      then
        indent 2 $ "match Js.Json.decodeArray json with"
        <$$> "| Some v ->"
        <$$> (indent 2 v)
        <$$> "| None -> Belt.Result.Error (\"" <> (stext name) <+> "expected an array.\")"
      else
        indent 2 $ "match (Aeson.Decode.unwrapResult (" <> decoder <+> "json))" <+> "with"
        <$$> "| v -> Belt.Result.Ok" <+> parens (stext name <+> "v")
        <$$> "| exception Aeson.Decode.DecodeError msg -> Belt.Result.Error (\"decode" <> (stext . textUppercaseFirst $ name) <> ": \" ^ msg)"

  render (OCamlValueConstructor (NamedConstructor name value@(OCamlRef _ _))) = do
    decoder <- render value
    let constructorParams = constructorParameters 0 value
    v <- mk name 0 $ (Just <$> flattenOCamlValue value) ++ [Nothing]
    pure $
      if length constructorParams > 1
      then
        indent 2 $ "match Js.Json.decodeArray json with"
        <$$> "| Some v ->"
        <$$> (indent 2 v)
        <$$> "| None -> Belt.Result.Error (\"" <> (stext name) <+> "expected an array.\")"
      else
        indent 2 $ "match (Aeson.Decode.unwrapResult (" <> decoder <+> "json))" <+> "with"
        <$$> "| v -> Belt.Result.Ok" <+> parens (stext name <+> "v")
        <$$> "| exception Aeson.Decode.DecodeError msg -> Belt.Result.Error (\"decode" <> (stext . textUppercaseFirst $ name) <> ": \" ^ msg)"

  render (OCamlValueConstructor (NamedConstructor name value)) = do
    decoder <- render value
    let constructorParams = constructorParameters 0 value
    v <- mk name 0 $ (Just <$> flattenOCamlValue value) ++ [Nothing]
    pure $
      if length constructorParams > 1
      then
        indent 2 $ "match Js.Json.decodeArray json with"
        <$$> "| Some v ->"
        <$$> (indent 2 v)
        <$$> "| None -> Belt.Result.Error (\"" <> (stext name) <+> "expected an array.\")"
      else
        indent 2 $ "match Aeson.Decode." <> decoder <+> "json" <+> "with"
        <$$> "| v -> Belt.Result.Ok" <+> parens (stext name <+> "v")
        <$$> "| exception Aeson.Decode.DecodeError msg -> Belt.Result.Error (\"decode" <> (stext . textUppercaseFirst $ name) <> ": \" ^ msg)"

  render (OCamlValueConstructor (RecordConstructor name value)) = do
    decoders <- render value
    pure
         $ "  match Aeson.Decode."
      <$$> (indent 4 ("{" <+> decoders <$$> "}"))
      <$$> "  with"
      <$$> "  | v -> Belt.Result.Ok v"
      <$$> "  | exception Aeson.Decode.DecodeError message -> Belt.Result.Error (\"decode" <> (stext . textUppercaseFirst $ name) <> ": \" ^ message)"

  render (OCamlValueConstructor (MultipleConstructors constructors)) = do
    decoders <- mapM (renderSum . OCamlValueConstructor) constructors
    pure $ indent 2 "match Aeson.Decode.(field \"tag\" string json) with"
      <$$> indent 2 (foldl (<$$>) "" decoders)
      <$$> indent 2 fnFooter
    where
      fnFooter = "| err -> Belt.Result.Error (\"Unknown tag value found '\" ^ err ^ \"'.\")"
            <$$> "| exception Aeson.Decode.DecodeError message -> Belt.Result.Error message"

  render _ = pure ""
    
instance HasDecoder OCamlValue where
  render ref@(OCamlRef typeRef name) = do
    mOCamlTypeMetaData <- asks topLevelOCamlTypeMetaData
    case mOCamlTypeMetaData of
      Nothing -> error $ "OCaml.BuckleScript.Decode (HasDecoder (OCamlRef typeRep name )) mOCamlTypeMetaData is Nothing:\n\n" ++ (show ref)
      Just ocamlTypeRef -> do
        ds <- asks (dependencies . userOptions)
        pure $ appendModule ds ocamlTypeRef typeRef name ""

  render ref@(OCamlRefApp typRep values) = do
    mOCamlTypeMetaData <- asks topLevelOCamlTypeMetaData
    case mOCamlTypeMetaData of
      Nothing -> error $ "OCaml.BuckleScript.Record (HasType (OCamlDatatype typeRep name)) mOCamlTypeMetaData is Nothing:\n\n" ++ (show ref)
      Just ocamlTypeRef -> do
        ds <- asks (dependencies . userOptions)
        dx <- renderRef values
        pure $ appendModule ds ocamlTypeRef (typeRepToHaskellTypeMetaData typRep) (T.pack $ show $ fst $ splitTyConApp typRep) (wrapIfPrimitive values dx)

  render (OCamlPrimitiveRef primitive) = renderRef primitive

  render (OCamlTypeParameterRef name) = pure $ "decode" <> (stext . textUppercaseFirst $ name)

  render (Values x y) = do
    dx <- render x
    dy <- render y
    pure $ dx <$$> ";" <+> dy

  render (OCamlRefAppValues x y) = do
    dx <- render x
    dy <- render y
    pure $ (wrapIfPrimitive x dx) <+> (wrapIfPrimitive y dy)

  render (OCamlField name value) = do
    ao <- asks (aesonOptions . userOptions)
    let jsonFieldname = T.pack . Aeson.fieldLabelModifier ao . T.unpack $ name    
    dv <- render value
    pure $ (stext name) <+> "=" <+> "field" <+> dquotes (stext jsonFieldname) <+> (unwrapIfTypeParameter value dv) <+> "json"

  render OCamlEmpty = pure ""

instance HasDecoder EnumeratorConstructor where
  render (EnumeratorConstructor name) = pure $ "| Some \"" <> stext name <> "\" -> Belt.Result.Ok" <+> stext name

instance HasDecoderRef OCamlValue where
  renderRef (OCamlRefAppValues x y) = do
    dx <- render x
    dy <- render y
    pure $ (wrapIfPrimitive x dx) <+> (wrapIfPrimitive y dy)

  renderRef (OCamlRef metadata ref) = do
    mOCamlTypeMetaData <- asks topLevelOCamlTypeMetaData
    case mOCamlTypeMetaData of
      Nothing -> error $ "OCaml.BuckleScript.Decode (HasDecoder (OCamlRef typeRep name)) mOCamlTypeMetaData is Nothing:\n\n" ++ (show ref)
      Just ocamlTypeRef -> do
        ds <- asks (dependencies . userOptions)
        pure $ stext (appendModule' ds ocamlTypeRef metadata ref)

  renderRef (OCamlPrimitiveRef primitive) = renderRef primitive

  renderRef _ = pure ""

instance HasDecoderRef OCamlPrimitive where
  renderRef OBool = pure "bool"
  renderRef OChar = pure "string"
  renderRef ODate = pure "date"
  renderRef OFloat = pure "Aeson.Decode.float" -- this is to prevent overshadowing warning
  renderRef OInt = pure "int"
  renderRef OInt32 = pure "int32"
  renderRef OString = pure "string"
  renderRef OUnit = pure $ parens "()"
  renderRef (OList (OCamlPrimitive OChar)) = pure "string"

  renderRef (OList v0) = do
    dv0 <- renderRefWithUnwrapResult v0
    pure . parens $ "list" <+> dv0

  renderRef (OOption v0) = do
    dv0 <- renderRefWithUnwrapResult v0
    pure . parens $ "optional" <+> dv0

  renderRef (OEither l r) = do
    dl <- renderRefWithUnwrapResult l
    dr <- renderRefWithUnwrapResult r
    pure $ parens $ "either" <+> dl <+> dr

  renderRef (OTuple2 v0 v1) = do
    dv0 <- renderRefWithUnwrapResult v0
    dv1 <- renderRefWithUnwrapResult v1
    pure $ parens $ "pair" <+> dv0 <+> dv1

  renderRef (OTuple3 v0 v1 v2) = do
    dv0 <- renderRefWithUnwrapResult v0
    dv1 <- renderRefWithUnwrapResult v1
    dv2 <- renderRefWithUnwrapResult v2
    pure $ parens $ "tuple3" <+> dv0 <+> dv1 <+> dv2

  renderRef (OTuple4 v0 v1 v2 v3) = do
    dv0 <- renderRefWithUnwrapResult v0
    dv1 <- renderRefWithUnwrapResult v1
    dv2 <- renderRefWithUnwrapResult v2
    dv3 <- renderRefWithUnwrapResult v3
    pure $ parens $ "tuple4" <+> dv0 <+> dv1 <+> dv2 <+> dv3

  renderRef (OTuple5 v0 v1 v2 v3 v4) = do
    dv0 <- renderRefWithUnwrapResult v0
    dv1 <- renderRefWithUnwrapResult v1
    dv2 <- renderRefWithUnwrapResult v2
    dv3 <- renderRefWithUnwrapResult v3
    dv4 <- renderRefWithUnwrapResult v4
    pure $ parens $ "tuple5" <+> dv0 <+> dv1 <+> dv2 <+> dv3 <+> dv4

  renderRef (OTuple6 v0 v1 v2 v3 v4 v5) = do
    dv0 <- renderRefWithUnwrapResult v0
    dv1 <- renderRefWithUnwrapResult v1
    dv2 <- renderRefWithUnwrapResult v2
    dv3 <- renderRefWithUnwrapResult v3
    dv4 <- renderRefWithUnwrapResult v4
    dv5 <- renderRefWithUnwrapResult v5
    pure $ parens $ "tuple6" <+> dv0 <+> dv1 <+> dv2 <+> dv3 <+> dv4 <+> dv5

-- Util
renderSumRecord :: Text -> OCamlConstructor -> Reader TypeMetaData (Maybe Doc)
renderSumRecord typeName (OCamlValueConstructor (RecordConstructor name value)) = do
  let sumRecordName = typeName <> name
  fnBody <- render (OCamlValueConstructor $ RecordConstructor (typeName <> name) value)
  ocamlInterface <- asks (includeOCamlInterface . userOptions)
  if ocamlInterface
    then
      pure $ Just $ "let decode" <> stext sumRecordName <+> "json =" <$$> fnBody
    else
      pure $ Just $ "let decode" <> stext sumRecordName <+> "(json : Js_json.t)" <+> ":(" <> (stext $ textLowercaseFirst sumRecordName) <> ", string)" <+> "Belt.Result.t =" <$$> fnBody

renderSumRecord _ _ = return Nothing

-- | Variable names for the members of constructors
--   Used in pattern matches
constructorParameters :: Int -> OCamlValue -> [Doc]
constructorParameters _ OCamlEmpty = [ empty ]
constructorParameters i (Values l r) =
    left ++ right
  where
    left = constructorParameters i l
    right = constructorParameters (length left + i) r
constructorParameters i _ = [ "y" <> int i ]

renderRefWithUnwrapResult :: OCamlDatatype -> Reader TypeMetaData Doc
renderRefWithUnwrapResult (OCamlDatatype typeRef _ (OCamlValueConstructor (NamedConstructor _ (OCamlRefApp typRep values)))) = do
  let name = "decode" <> (stext $ textUppercaseFirst $ T.pack $ show $ fst $ splitTyConApp typRep)
  dx <- renderRef values

  mOCamlTypeMetaData <- asks topLevelOCamlTypeMetaData 
  case mOCamlTypeMetaData of
    Nothing -> pure $ parens $ name <+> (wrapIfPrimitive values dx)
    Just decOCamlTypeMetaData -> do
      ds <- asks (dependencies . userOptions)
      case Map.lookup (typeRepToHaskellTypeMetaData typRep) ds of
        Just parOCamlTypeMetaData -> do
          let prefix = stext $ mkModulePrefix decOCamlTypeMetaData parOCamlTypeMetaData          
          pure $ parens $ "fun a -> unwrapResult (" <> prefix <> name <+> (wrapIfPrimitive values dx) <+> "a)"
        Nothing -> error ("OCaml.BuckleScript.Decode (HasDecoderRef OCamlDataType) expected to find dependency:\n\n" ++ show typeRef ++ "\n\nin\n\n" ++ show ds)

renderRefWithUnwrapResult datatype@(OCamlDatatype typeRef name _) = do
  if isTypeParameterRef datatype
  then
    pure . parens $ "fun a -> unwrapResult (decode" <> (stext . textUppercaseFirst $ name) <+> "a)"
  else do
    mOCamlTypeMetaData <- asks topLevelOCamlTypeMetaData
    case mOCamlTypeMetaData of
      Nothing -> error $ "OCaml.BuckleScript.Decode.renderRefWithUnwrapResult mOCamlTypeMetaData is Nothing:\n\n" ++ (show datatype)
      Just decOCamlTypeMetaData -> do
        ds <- asks (dependencies . userOptions)
        case Map.lookup typeRef ds of
          Just parOCamlTypeMetaData -> do
            let prefix = stext $ mkModulePrefix decOCamlTypeMetaData parOCamlTypeMetaData
            pure . parens $ "fun a -> unwrapResult (" <> prefix <> "decode" <> (stext . textUppercaseFirst $ name) <+> "a)"
          Nothing -> error ("OCaml.BuckleScript.Decode.renderRefWithUnwrapResult expected to find dependency:\n\n" ++ show typeRef ++ "\n\nin\n\n" ++ show ds)
renderRefWithUnwrapResult ref = renderRef ref

    
-- | "<name>" -> decode <name>
renderSumCondition :: T.Text -> Doc -> Reader TypeMetaData Doc
renderSumCondition name contents = do
  ao <- asks (aesonOptions . userOptions)
  let jsonConstructorName = T.pack . Aeson.constructorTagModifier ao . T.unpack $ name
  pure $ "|" <+> dquotes (stext jsonConstructorName) <+> "->" <$$>
    indent 3 contents

-- | Render a sum type constructor in context of a data type with multiple
-- constructors.
renderSum :: OCamlConstructor -> Reader TypeMetaData Doc
renderSum (OCamlValueConstructor (NamedConstructor name OCamlEmpty)) = renderSumCondition name ("Belt.Result.Ok" <+> stext name) 
renderSum (OCamlValueConstructor (NamedConstructor name v@(Values _ _))) = do
  val <- rArgs name v
  renderSumCondition name val

renderSum (OCamlValueConstructor (NamedConstructor name value)) = do
  ao <- asks (aesonOptions . userOptions)
  let jsonConstructorName = T.pack . Aeson.constructorTagModifier ao . T.unpack $ name
  val <- render value
  renderSumCondition name $ parens
    ("match Aeson.Decode." <> parens ("field \"contents\"" <+> (unwrapIfTypeParameter value val) <+> "json") <+> "with"
      <$$>
        indent 1
          (    "| v -> Belt.Result.Ok (" <> (stext name) <+> "v)"
          <$$> "| exception Aeson.Decode.DecodeError message -> Belt.Result.Error (\"" <> (stext jsonConstructorName) <> ": \" ^ message)"
          )           <> line
    )

renderSum (OCamlValueConstructor (RecordConstructor name value)) = do
  val <- render value
  renderSumCondition name val

renderSum (OCamlValueConstructor (MultipleConstructors constrs)) =
  foldl1 (<$+$>) <$> mapM (renderSum . OCamlValueConstructor) constrs

renderSum (OCamlSumOfRecordConstructor typeName (RecordConstructor name _value)) =
  renderOutsideEncoder typeName name

renderSum (OCamlSumOfRecordConstructor typeName (MultipleConstructors constrs)) =
  foldl1 (<$+$>) <$> mapM renderSum (OCamlSumOfRecordConstructor typeName <$> constrs)

renderSum (OCamlEnumeratorConstructor _) = pure "" -- handled elsewhere
renderSum _ = pure ""

renderOutsideEncoder :: Text -> Text -> Reader TypeMetaData Doc
renderOutsideEncoder typeName name =
  pure $
        "|" <+> (dquotes . stext $ name) <+> "->"
   <$$> indent 3 ("(match" <+> "decode" <> (stext $ typeName <> textUppercaseFirst name) <+> "json" <+> "with"
   <$$> indent 1 ("| Belt.Result.Ok v -> Belt.Result.Ok" <+> (parens ((stext $ textUppercaseFirst name) <+> "v"))
   <$$> "| Belt.Result.Error message -> Belt.Result.Error" <+> (parens $ (dquotes $ "decode" <> stext typeName <> ": ") <+> "^ message"))
   <$$> ")")


flattenOCamlValue :: OCamlValue -> [OCamlValue]
flattenOCamlValue (Values l r) = flattenOCamlValue l ++ flattenOCamlValue r
flattenOCamlValue val = [val]

-- | Render the decoding of a constructor's arguments. Note the constructor must
--   be from a data type with multiple constructors and that it has multiple
--   constructors itself.
rArgs :: Text -> OCamlValue -> Reader TypeMetaData Doc
rArgs name vals = do
  v <- mk name 0 $ (Just <$> flattenOCamlValue vals) ++ [Nothing]
  pure $
    parens $ "match Aeson.Decode.(field \"contents\" Js.Json.decodeArray json) with"
    <$$> (indent 1 "| Some v ->"
    <$$> (indent 3 v)
    <$$> (indent 1 "| None -> Belt.Result.Error (\"" <> (stext name) <+> "expected an array.\")" )) <> line

mk :: Text -> Int -> [Maybe OCamlValue] -> Reader TypeMetaData Doc
mk name i [x] =
  case x of
    Nothing -> do
      let ts = foldl (<>) "" $ L.intersperse ", " ((stext . T.append "v" . T.pack . show) <$> [0..i-1])
      pure $ indent 1 $ "Belt.Result.Ok" <+> parens (stext name <+> parens ts)
    Just _ -> pure ""
mk name i (x:xs) =
  case x of
    Nothing -> mk name i xs
    Just x' -> do
      renderedVal <- unwrapIfTypeParameter x' <$> render x'
      renderedInternal <- mk name (i+1) xs
      let iDoc = (stext . T.pack . show $ i)
      pure $ indent 1 $ "(match" <+> "Aeson.Decode.(" <> renderedVal <> (") v." <> parens iDoc) <+> "with"
        <$$>
          indent 1
            ("| v" <> iDoc <+> "->" <$$> (indent 2 renderedInternal)
            <$$> "| exception Aeson.Decode.DecodeError message -> Belt.Result.Error (\"" <> (stext name) <> ": \" ^ message)"
            )
        <$$> ")"

mk _name _i [] = pure ""

renderTypeParameterValsAux :: [OCamlValue] -> (Doc,Doc)
renderTypeParameterValsAux ocamlValues =
  let typeParameterNames = (<>) "'" <$> (L.sort $ getTypeParameterRefNames ocamlValues)
      typeDecs = (foldl (<>) "" $ L.intersperse " -> " $ (\t -> "(Js_json.t -> (" <> (stext t) <> ", string) Belt.Result.t)") <$> typeParameterNames) <> " -> "
  in
      if length typeParameterNames > 0
      then
        if length typeParameterNames > 1
          then (typeDecs, foldl (<>) "" $ ["("] <> (L.intersperse ", " $ stext <$> typeParameterNames) <> [") "])
          else (typeDecs, stext . flip (<>) " " . head $ typeParameterNames)
      else ("","")

renderTypeParameterVals :: OCamlConstructor -> (Doc,Doc)
renderTypeParameterVals (OCamlValueConstructor vc) = renderTypeParameterValsAux $ getOCamlValues vc
renderTypeParameterVals (OCamlSumOfRecordConstructor _ vc) = renderTypeParameterValsAux $ getOCamlValues vc
renderTypeParameterVals _ = ("","")


renderTypeParametersAux :: [OCamlValue] -> (Doc,Doc)
renderTypeParametersAux ocamlValues = do
  let typeParameterNames = getTypeParameterRefNames ocamlValues
      typeDecs = (\t -> "(type " <> (stext t) <> ")") <$> typeParameterNames :: [Doc]
      encoderDecs  = (\t -> "(decode" <> (stext $ textUppercaseFirst t) <+> ":" <+> "Js_json.t -> (" <> (stext t) <> ", string) Belt.Result.t)" ) <$> typeParameterNames :: [Doc]
      typeParams = foldl (<>) "" $ if length typeParameterNames > 1 then  ["("] <> (L.intersperse ", " $ stext <$> typeParameterNames) <> [") "] else ((\x -> stext $ x <> " ") <$> typeParameterNames) :: [Doc]
  (foldl (<+>) "" (typeDecs ++ encoderDecs), typeParams )

getOCamlValues :: ValueConstructor -> [OCamlValue]
getOCamlValues (NamedConstructor     _ value) = [value]
getOCamlValues (RecordConstructor    _ value) = [value]
getOCamlValues (MultipleConstructors cs)      = concat $ getOCamlValues <$> cs

renderTypeParameters :: OCamlConstructor -> (Doc,Doc)
renderTypeParameters (OCamlValueConstructor vc) = renderTypeParametersAux $ getOCamlValues vc
renderTypeParameters (OCamlSumOfRecordConstructor _ vc) = renderTypeParametersAux $ getOCamlValues vc
renderTypeParameters _ = ("","")

-- | Render an OCaml val interface for a record constructor in a sum of records
renderSumRecordInterface :: Text -> OCamlConstructor -> Maybe Doc
renderSumRecordInterface typeName (OCamlValueConstructor (RecordConstructor name _value)) =
  Just $ "val decode" <> (stext $ typeName <> name) <+> ":" <+> "Js_json.t" <+> "->" <+> parens (stext (textLowercaseFirst $ typeName <> name) <> comma <+> "string") <+> "Belt.Result.t"
renderSumRecordInterface _ _ = Nothing

-- | If this type comes from a different OCaml module, then add the appropriate module prefix and add unwrapResult to make the
--   types match
appendModule :: Map.Map HaskellTypeMetaData OCamlTypeMetaData -> OCamlTypeMetaData -> HaskellTypeMetaData -> Text -> Doc -> Doc
appendModule m o h name nxt =
  case Map.lookup h m of
    Just parOCamlTypeMetaData ->
      (stext $ mkModulePrefix o parOCamlTypeMetaData) <> "decode" <> (stext $ textUppercaseFirst name) <+> nxt
    -- in case of a Haskell sum of products, ocaml-export creates a definition for each product
    -- within the same file as the sum. These products will not be in the dependencies map.
    Nothing -> "decode"  <> (stext $ textUppercaseFirst name) <+> nxt

appendModule' :: Map.Map HaskellTypeMetaData OCamlTypeMetaData -> OCamlTypeMetaData -> HaskellTypeMetaData -> Text -> Text
appendModule' m o h name =
  case Map.lookup h m of
    Just parOCamlTypeMetaData -> 
      (mkModulePrefix o parOCamlTypeMetaData) <>  "decode" <> (textUppercaseFirst name)
    -- in case of a Haskell sum of products, ocaml-export creates a definition for each product
    -- within the same file as the sum. These products will not be in the dependencies map.
    Nothing -> "decode" <> textUppercaseFirst name


wrapIfPrimitive :: OCamlValue -> Doc -> Doc
wrapIfPrimitive (OCamlPrimitiveRef _) doc = parens $ "wrapResult" <+> doc
wrapIfPrimitive _ doc = doc

unwrapIfTypeParameter :: OCamlValue -> Doc -> Doc
unwrapIfTypeParameter (OCamlTypeParameterRef _) doc = parens $ "fun a -> unwrapResult" <+> (parens $ doc <+> "a")
unwrapIfTypeParameter (OCamlRef _ _) doc = parens $ "fun a -> unwrapResult" <+> (parens $ doc <+> "a")
unwrapIfTypeParameter (OCamlRefApp _ _) doc = parens $ "fun a -> unwrapResult" <+> (parens $ doc <+> "a")
unwrapIfTypeParameter _ doc = doc
