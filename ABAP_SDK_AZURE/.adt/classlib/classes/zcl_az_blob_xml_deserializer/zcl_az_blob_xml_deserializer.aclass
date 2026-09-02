* Copyright (c) Microsoft Corporation.
* Licensed under the MIT license.

CLASS zcl_az_blob_xml_deserializer DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC .

  PUBLIC SECTION.

    "! The user delegation key returned by Get User Delegation Key. All fields are
    "! kept as the exact strings Azure returned, because User Delegation SAS
    "! signing must feed the signed-key fields (skoid/sktid/skt/ske/sks/skv) back
    "! verbatim into the StringToSign.
    TYPES: BEGIN OF ty_user_delegation_key,
             signed_oid     TYPE string,   " skoid
             signed_tid     TYPE string,   " sktid
             signed_start   TYPE string,   " skt (ISO8601)
             signed_expiry  TYPE string,   " ske (ISO8601)
             signed_service TYPE string,   " sks
             signed_version TYPE string,   " skv
             value          TYPE string,   " base64-encoded key
           END OF ty_user_delegation_key.

    CLASS-METHODS deserialize_list_containers
      IMPORTING
        iv_xml           TYPE xstring
      RETURNING
        VALUE(ro_result) TYPE REF TO zcl_az_list_containers_result
      RAISING
        zcx_az_serialization_error.

    CLASS-METHODS deserialize_list_blobs
      IMPORTING
        iv_xml           TYPE xstring
      RETURNING
        VALUE(ro_result) TYPE REF TO zcl_az_list_blobs_result
      RAISING
        zcx_az_serialization_error.

    "! Parse a <UserDelegationKey> XML document (from Get User Delegation Key)
    "! into its signed-key fields. Raises on empty/malformed XML.
    CLASS-METHODS deserialize_user_deleg_key
      IMPORTING
        iv_xml        TYPE xstring
      RETURNING
        VALUE(rs_key) TYPE ty_user_delegation_key
      RAISING
        zcx_az_serialization_error.


  PROTECTED SECTION.
  PRIVATE SECTION.

    "! Parse an XML payload into an ixml document (or raise on malformed XML).
    CLASS-METHODS parse_document
      IMPORTING
        iv_xml             TYPE xstring
      RETURNING
        VALUE(ro_document) TYPE REF TO if_ixml_document
      RAISING
        zcx_az_serialization_error.

    "! Text of the first descendant element named iv_tag under io_node ('' if none).
    CLASS-METHODS child_value
      IMPORTING
        io_node       TYPE REF TO if_ixml_node
        iv_tag        TYPE string
      RETURNING
        VALUE(rv_value) TYPE string.

ENDCLASS.


CLASS zcl_az_blob_xml_deserializer IMPLEMENTATION.

METHOD deserialize_list_containers.

  DATA lo_result         TYPE REF TO zcl_az_list_containers_result.
  DATA lo_ixml           TYPE REF TO if_ixml_core.
  DATA lo_streamfactory  TYPE REF TO if_ixml_stream_factory_core.
  DATA lo_istream        TYPE REF TO if_ixml_istream_core.
  DATA lo_parser         TYPE REF TO if_ixml_parser_core.
  DATA lo_document       TYPE REF TO if_ixml_document.
  DATA lo_node_list      TYPE REF TO if_ixml_node_collection.
  DATA lv_length         TYPE i.
  DATA lv_index          TYPE i VALUE 0.
  DATA lv_rc             TYPE i.

  " Guard: XML payload must not be empty
  IF iv_xml IS INITIAL.
    RAISE EXCEPTION TYPE zcx_az_serialization_error
      EXPORTING
        iv_message = |Cannot deserialize: XML payload is empty.|.
  ENDIF.

  lo_result = NEW zcl_az_list_containers_result( ).

  TRY.
      lo_ixml          = cl_ixml_core=>create( ).
      lo_document      = lo_ixml->create_document( ).
      lo_streamfactory = lo_ixml->create_stream_factory( ).
      lo_istream       = lo_streamfactory->create_istream_xstring( iv_xml ).

      lo_parser = lo_ixml->create_parser(
                    stream_factory = lo_streamfactory
                    istream        = lo_istream
                    document       = lo_document ).

      lv_rc = lo_parser->parse( ).

      " Non-zero return code indicates malformed XML
      IF lv_rc <> 0.
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |Failed to parse XML: parser returned { lv_rc }.|.
      ENDIF.

      lo_node_list = lo_document->get_elements_by_tag_name( name = 'Name' ).
      lv_length    = lo_node_list->get_length( ).

      WHILE lv_index < lv_length.
        DATA(lo_node) = lo_node_list->get_item( lv_index ).
        IF lo_node IS BOUND.
          APPEND lo_node->get_value( ) TO lo_result->mt_containers.
        ENDIF.
        lv_index = lv_index + 1.
      ENDWHILE.

      " Continuation token for paging (empty element = last page)
      DATA(lo_nm) = lo_document->get_elements_by_tag_name( name = 'NextMarker' ).
      IF lo_nm->get_length( ) > 0 AND lo_nm->get_item( 0 ) IS BOUND.
        lo_result->mv_next_marker = lo_nm->get_item( 0 )->get_value( ).
      ENDIF.

    CATCH zcx_az_serialization_error.
      " Re-raise our own guard/parse exceptions unchanged
      RAISE EXCEPTION TYPE zcx_az_serialization_error
        EXPORTING
          iv_message = |XML deserialization of container list failed.|.

    CATCH cx_root INTO DATA(lx_error).
      RAISE EXCEPTION TYPE zcx_az_serialization_error
        EXPORTING
          iv_message = |Unexpected error during XML deserialization. { lx_error->get_text( ) }|
          previous   = lx_error.
  ENDTRY.

  ro_result = lo_result.

ENDMETHOD.


METHOD deserialize_list_blobs.

  DATA lv_index TYPE i.
  DATA ls_blob  TYPE zcl_az_list_blobs_result=>ty_blob.

  IF iv_xml IS INITIAL.
    RAISE EXCEPTION TYPE zcx_az_serialization_error
      EXPORTING
        iv_message = |Cannot deserialize: XML payload is empty.|.
  ENDIF.

  ro_result = NEW zcl_az_list_blobs_result( ).

  TRY.
      DATA(lo_document) = parse_document( iv_xml ).

      " --- blobs ---
      DATA(lo_blobs) = lo_document->get_elements_by_tag_name( name = 'Blob' ).
      lv_index = 0.
      WHILE lv_index < lo_blobs->get_length( ).
        DATA(lo_blob) = lo_blobs->get_item( lv_index ).
        IF lo_blob IS BOUND.
          CLEAR ls_blob.
          ls_blob-name          = child_value( io_node = lo_blob iv_tag = 'Name' ).
          ls_blob-content_type  = child_value( io_node = lo_blob iv_tag = 'Content-Type' ).
          ls_blob-etag          = child_value( io_node = lo_blob iv_tag = 'Etag' ).
          ls_blob-last_modified = child_value( io_node = lo_blob iv_tag = 'Last-Modified' ).
          ls_blob-blob_type     = child_value( io_node = lo_blob iv_tag = 'BlobType' ).
          DATA(lv_len) = child_value( io_node = lo_blob iv_tag = 'Content-Length' ).
          IF lv_len IS NOT INITIAL AND lv_len CO '0123456789'.
            ls_blob-content_length = lv_len.
          ENDIF.
          APPEND ls_blob TO ro_result->mt_blobs.
        ENDIF.
        lv_index = lv_index + 1.
      ENDWHILE.

      " --- virtual directories rolled up by a delimiter ---
      DATA(lo_prefixes) = lo_document->get_elements_by_tag_name( name = 'BlobPrefix' ).
      lv_index = 0.
      WHILE lv_index < lo_prefixes->get_length( ).
        DATA(lo_pref) = lo_prefixes->get_item( lv_index ).
        IF lo_pref IS BOUND.
          APPEND child_value( io_node = lo_pref iv_tag = 'Name' ) TO ro_result->mt_prefixes.
        ENDIF.
        lv_index = lv_index + 1.
      ENDWHILE.

      " --- continuation token ---
      DATA(lo_nm) = lo_document->get_elements_by_tag_name( name = 'NextMarker' ).
      IF lo_nm->get_length( ) > 0 AND lo_nm->get_item( 0 ) IS BOUND.
        ro_result->mv_next_marker = lo_nm->get_item( 0 )->get_value( ).
      ENDIF.

    CATCH zcx_az_serialization_error.
      RAISE EXCEPTION TYPE zcx_az_serialization_error
        EXPORTING
          iv_message = |XML deserialization of blob list failed.|.

    CATCH cx_root INTO DATA(lx_error).
      RAISE EXCEPTION TYPE zcx_az_serialization_error
        EXPORTING
          iv_message = |Unexpected error during XML deserialization. { lx_error->get_text( ) }|
          previous   = lx_error.
  ENDTRY.

ENDMETHOD.


METHOD deserialize_user_deleg_key.

  IF iv_xml IS INITIAL.
    RAISE EXCEPTION TYPE zcx_az_serialization_error
      EXPORTING
        iv_message = |Cannot deserialize: UserDelegationKey XML is empty.|.
  ENDIF.

  TRY.
      DATA(lo_document) = parse_document( iv_xml ).
      DATA(lo_root)     = lo_document->get_root_element( ).

      IF lo_root IS NOT BOUND.
        RAISE EXCEPTION TYPE zcx_az_serialization_error
          EXPORTING
            iv_message = |UserDelegationKey XML has no root element.|.
      ENDIF.

      rs_key-signed_oid     = child_value( io_node = lo_root iv_tag = 'SignedOid' ).
      rs_key-signed_tid     = child_value( io_node = lo_root iv_tag = 'SignedTid' ).
      rs_key-signed_start   = child_value( io_node = lo_root iv_tag = 'SignedStart' ).
      rs_key-signed_expiry  = child_value( io_node = lo_root iv_tag = 'SignedExpiry' ).
      rs_key-signed_service = child_value( io_node = lo_root iv_tag = 'SignedService' ).
      rs_key-signed_version = child_value( io_node = lo_root iv_tag = 'SignedVersion' ).
      rs_key-value          = child_value( io_node = lo_root iv_tag = 'Value' ).

    CATCH zcx_az_serialization_error.
      RAISE EXCEPTION TYPE zcx_az_serialization_error
        EXPORTING
          iv_message = |XML deserialization of the user delegation key failed.|.

    CATCH cx_root INTO DATA(lx_error).
      RAISE EXCEPTION TYPE zcx_az_serialization_error
        EXPORTING
          iv_message = |Unexpected error during XML deserialization. { lx_error->get_text( ) }|
          previous   = lx_error.
  ENDTRY.

ENDMETHOD.


METHOD parse_document.

  DATA lo_ixml          TYPE REF TO if_ixml_core.
  DATA lo_streamfactory TYPE REF TO if_ixml_stream_factory_core.
  DATA lo_istream       TYPE REF TO if_ixml_istream_core.
  DATA lo_parser        TYPE REF TO if_ixml_parser_core.

  lo_ixml          = cl_ixml_core=>create( ).
  ro_document      = lo_ixml->create_document( ).
  lo_streamfactory = lo_ixml->create_stream_factory( ).
  lo_istream       = lo_streamfactory->create_istream_xstring( iv_xml ).

  lo_parser = lo_ixml->create_parser(
                stream_factory = lo_streamfactory
                istream        = lo_istream
                document       = ro_document ).

  IF lo_parser->parse( ) <> 0.
    RAISE EXCEPTION TYPE zcx_az_serialization_error
      EXPORTING
        iv_message = |Failed to parse XML payload.|.
  ENDIF.

ENDMETHOD.


METHOD child_value.

  DATA(lo_element) = CAST if_ixml_element( io_node ).
  DATA(lo_list)    = lo_element->get_elements_by_tag_name( name = iv_tag ).

  IF lo_list->get_length( ) > 0.
    DATA(lo_item) = lo_list->get_item( 0 ).
    IF lo_item IS BOUND.
      rv_value = lo_item->get_value( ).
    ENDIF.
  ENDIF.

ENDMETHOD.


ENDCLASS.
