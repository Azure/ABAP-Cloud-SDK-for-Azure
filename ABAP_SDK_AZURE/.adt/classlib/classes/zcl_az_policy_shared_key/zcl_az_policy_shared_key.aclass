* Copyright (c) Microsoft Corporation.
* Licensed under the MIT license.

CLASS zcl_az_policy_shared_key DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.

    "! Pipeline policy that authenticates storage requests with the Shared Key
    "! (account key) scheme. Unlike AAD auth or SAS, Shared Key computes an
    "! HMAC-SHA256 signature over a canonicalized representation of the request
    "! (verb, standard headers, all x-ms-* headers and the resource path/query)
    "! and sends it in an "Authorization: SharedKey <account>:<signature>"
    "! header. Use this policy in place of zcl_az_policy_auth when authenticating
    "! with a storage account key.
    INTERFACES zif_az_http_pipeline_policy.

    METHODS constructor
      IMPORTING
        iv_account_name TYPE string
        iv_account_key  TYPE string.

    "! Build the StringToSign for the Shared Key (full) scheme. Reads the verb,
    "! conditional headers, Content-Length/Content-Type, the canonicalized
    "! x-ms-* headers and the canonicalized resource from the request.
    CLASS-METHODS build_string_to_sign
      IMPORTING
        io_request    TYPE REF TO zcl_az_http_request
        iv_account    TYPE string
      RETURNING
        VALUE(rv_sts) TYPE string.

    "! Canonicalized headers block: every x-ms-* header, name lower-cased and
    "! value white-space-condensed, sorted lexicographically, each terminated
    "! by a line feed.
    CLASS-METHODS canonicalized_headers
      IMPORTING
        it_headers TYPE zcl_az_http_request=>ty_t_headers
      RETURNING
        VALUE(rv)  TYPE string.

    "! Canonicalized resource: "/{account}{path}" followed by every query
    "! parameter (name lower-cased), sorted, one per line as "\nname:value"
    "! (comma-joining values that share a name).
    CLASS-METHODS canonicalized_resource
      IMPORTING
        iv_account TYPE string
        iv_url     TYPE string
      RETURNING
        VALUE(rv)  TYPE string.

  PRIVATE SECTION.

    DATA mv_account TYPE string.
    DATA mv_key     TYPE string.

    "! Case-insensitive lookup of a header value ("name:value" lines). Returns
    "! the white-space-condensed value, or an empty string when absent.
    CLASS-METHODS header_value
      IMPORTING
        it_headers TYPE zcl_az_http_request=>ty_t_headers
        iv_name    TYPE string
      RETURNING
        VALUE(rv)  TYPE string.

    "! Content-Length for StringToSign. Per Azure version 2014-02-14 and later
    "! a zero length must be signed as an empty string, so a body-less request
    "! returns ''.
    CLASS-METHODS content_length
      IMPORTING
        io_request TYPE REF TO zcl_az_http_request
      RETURNING
        VALUE(rv)  TYPE string.

    METHODS sign
      IMPORTING
        iv_string_to_sign TYPE string
      RETURNING
        VALUE(rv)         TYPE string
      RAISING
        zcx_az_http_error.

    METHODS rfc1123_now
      RETURNING VALUE(rv) TYPE string.

ENDCLASS.



CLASS zcl_az_policy_shared_key IMPLEMENTATION.

  METHOD constructor.
    mv_account = iv_account_name.
    mv_key     = iv_account_key.
  ENDMETHOD.


  METHOD zif_az_http_pipeline_policy~process.

    " Guard: required inputs must be bound
    IF io_context IS INITIAL OR io_request IS INITIAL.
      RAISE EXCEPTION TYPE zcx_az_http_error
        EXPORTING
          iv_status_code = 0
          iv_message     = |Invalid request: context or request is not bound.|.
    ENDIF.

    " Guard: account name + key must be available
    IF mv_account IS INITIAL OR mv_key IS INITIAL.
      RAISE EXCEPTION TYPE zcx_az_http_error
        EXPORTING
          iv_status_code = 0
          iv_message     = |Authentication failed: storage account name or key is not set.|.
    ENDIF.

    " Storage requires an x-ms-date (preferred over Date) and an x-ms-version.
    " Both participate in the canonicalized headers, so they must be present
    " before the StringToSign is built.
    IF header_value( it_headers = io_request->mt_headers iv_name = 'x-ms-date' ) IS INITIAL.
      APPEND |x-ms-date:{ rfc1123_now( ) }| TO io_request->mt_headers.
    ENDIF.
    IF header_value( it_headers = io_request->mt_headers iv_name = 'x-ms-version' ) IS INITIAL.
      APPEND |x-ms-version:2023-11-03| TO io_request->mt_headers.
    ENDIF.

    DATA(lv_sts) = build_string_to_sign( io_request = io_request iv_account = mv_account ).
    DATA(lv_sig) = sign( lv_sts ).

    APPEND |Authorization: SharedKey { mv_account }:{ lv_sig }| TO io_request->mt_headers.

    " Defensive: a failure in the downstream pipeline must surface cleanly
    TRY.
        ro_response = io_context->next( io_request ).

      CATCH zcx_az_http_error INTO DATA(lx_http_err).
        RAISE EXCEPTION lx_http_err.

      CATCH cx_root INTO DATA(lx_next_error).
        RAISE EXCEPTION TYPE zcx_az_http_error
          EXPORTING
            iv_status_code = 0
            iv_message     = |HTTP request failed in shared-key policy.|
            previous       = lx_next_error.
    ENDTRY.

  ENDMETHOD.


  METHOD build_string_to_sign.

    DATA(lv_lf) = cl_abap_char_utilities=>newline.

    rv_sts =
         io_request->mv_method                                                                 && lv_lf
      && header_value( it_headers = io_request->mt_headers iv_name = 'Content-Encoding' )       && lv_lf
      && header_value( it_headers = io_request->mt_headers iv_name = 'Content-Language' )       && lv_lf
      && content_length( io_request )                                                           && lv_lf
      && header_value( it_headers = io_request->mt_headers iv_name = 'Content-MD5' )            && lv_lf
      && header_value( it_headers = io_request->mt_headers iv_name = 'Content-Type' )           && lv_lf
      "" Date is intentionally empty: x-ms-date is supplied and takes precedence
      && ``                                                                                     && lv_lf
      && header_value( it_headers = io_request->mt_headers iv_name = 'If-Modified-Since' )      && lv_lf
      && header_value( it_headers = io_request->mt_headers iv_name = 'If-Match' )               && lv_lf
      && header_value( it_headers = io_request->mt_headers iv_name = 'If-None-Match' )          && lv_lf
      && header_value( it_headers = io_request->mt_headers iv_name = 'If-Unmodified-Since' )    && lv_lf
      && header_value( it_headers = io_request->mt_headers iv_name = 'Range' )                  && lv_lf
      && canonicalized_headers( io_request->mt_headers )
      && canonicalized_resource( iv_account = iv_account iv_url = io_request->mv_url ).

  ENDMETHOD.


  METHOD canonicalized_headers.

    TYPES: BEGIN OF ty_kv,
             name  TYPE string,
             value TYPE string,
           END OF ty_kv.
    DATA lt TYPE STANDARD TABLE OF ty_kv WITH DEFAULT KEY.

    LOOP AT it_headers INTO DATA(lv_h).
      IF lv_h IS INITIAL.
        CONTINUE.
      ENDIF.
      SPLIT lv_h AT ':' INTO DATA(lv_n) DATA(lv_v).
      lv_n = to_lower( condense( lv_n ) ).
      IF lv_n CP 'x-ms-*'.
        APPEND VALUE #( name = lv_n value = condense( lv_v ) ) TO lt.
      ENDIF.
    ENDLOOP.

    SORT lt BY name value.

    DATA(lv_lf) = cl_abap_char_utilities=>newline.
    DATA lv_last TYPE string VALUE `~`.
    LOOP AT lt INTO DATA(ls).
      IF ls-name <> lv_last.
        rv = rv && ls-name && ':' && ls-value && lv_lf.
        lv_last = ls-name.
      ELSE.
        " same header repeated: append the value to the previous line
        rv = substring( val = rv off = 0 len = strlen( rv ) - strlen( lv_lf ) )
           && ',' && ls-value && lv_lf.
      ENDIF.
    ENDLOOP.

  ENDMETHOD.


  METHOD canonicalized_resource.

    " Strip scheme + host, keeping the absolute path and query string.
    DATA lv_rest TYPE string.
    SPLIT iv_url AT '://' INTO DATA(lv_scheme) lv_rest.
    IF lv_rest IS INITIAL.
      lv_rest = iv_url.
    ENDIF.

    DATA lv_hostpath TYPE string.
    FIND FIRST OCCURRENCE OF '/' IN lv_rest MATCH OFFSET DATA(lv_off).
    IF sy-subrc = 0.
      lv_hostpath = lv_rest+lv_off.
    ELSE.
      lv_hostpath = '/'.
    ENDIF.

    DATA lv_path  TYPE string.
    DATA lv_query TYPE string.
    SPLIT lv_hostpath AT '?' INTO lv_path lv_query.

    rv = '/' && iv_account && lv_path.

    IF lv_query IS INITIAL.
      RETURN.
    ENDIF.

    TYPES: BEGIN OF ty_kv,
             name  TYPE string,
             value TYPE string,
           END OF ty_kv.
    DATA lt TYPE STANDARD TABLE OF ty_kv WITH DEFAULT KEY.

    SPLIT lv_query AT '&' INTO TABLE DATA(lt_pairs).
    LOOP AT lt_pairs INTO DATA(lv_pair).
      IF lv_pair IS INITIAL.
        CONTINUE.
      ENDIF.
      SPLIT lv_pair AT '=' INTO DATA(lv_pn) DATA(lv_pv).
      APPEND VALUE #( name = to_lower( lv_pn ) value = lv_pv ) TO lt.
    ENDLOOP.

    SORT lt BY name value.

    DATA(lv_lf) = cl_abap_char_utilities=>newline.
    DATA lv_last TYPE string VALUE `~`.
    LOOP AT lt INTO DATA(ls).
      IF ls-name <> lv_last.
        rv = rv && lv_lf && ls-name && ':' && ls-value.
        lv_last = ls-name.
      ELSE.
        rv = rv && ',' && ls-value.
      ENDIF.
    ENDLOOP.

  ENDMETHOD.


  METHOD header_value.

    DATA(lv_target) = to_lower( iv_name ).
    LOOP AT it_headers INTO DATA(lv_h).
      SPLIT lv_h AT ':' INTO DATA(lv_n) DATA(lv_v).
      IF to_lower( condense( lv_n ) ) = lv_target.
        rv = condense( lv_v ).
        RETURN.
      ENDIF.
    ENDLOOP.

  ENDMETHOD.


  METHOD content_length.

    IF io_request->mv_body_bin IS NOT INITIAL.
      rv = |{ xstrlen( io_request->mv_body_bin ) }|.
    ELSEIF io_request->mv_body IS NOT INITIAL.
      DATA(lv_x) = cl_abap_conv_codepage=>create_out( codepage = 'UTF-8' )->convert( io_request->mv_body ).
      rv = |{ xstrlen( lv_x ) }|.
    ELSE.
      " body-less request: sign Content-Length as empty (version 2014-02-14+)
      rv = ``.
    ENDIF.

  ENDMETHOD.


  METHOD sign.

    " HMAC-SHA256 over the StringToSign, keyed with the base64 account key.
    " Delegates to the shared zcl_az_crypto helper (also used by UDK SAS signing)
    " and re-wraps its typed error as the pipeline's zcx_az_http_error.
    TRY.
        rv = zcl_az_crypto=>hmac_sha256_b64(
               iv_key_base64 = mv_key
               iv_data       = iv_string_to_sign ).
      CATCH zcx_az_serialization_error INTO DATA(lx).
        RAISE EXCEPTION TYPE zcx_az_http_error
          EXPORTING
            iv_status_code = 0
            iv_message     = |Shared Key signing failed: { lx->get_text( ) }|
            previous       = lx.
    ENDTRY.

  ENDMETHOD.


  METHOD rfc1123_now.

    CONSTANTS lc_days  TYPE string VALUE 'Mon Tue Wed Thu Fri Sat Sun'.
    CONSTANTS lc_month TYPE string VALUE 'Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec'.
    " 2024-01-01 was a Monday - used as a reference to derive the weekday with
    " pure date arithmetic (no classic function module, ABAP-Cloud safe).
    CONSTANTS lc_ref_monday TYPE d VALUE '20240101'.

    DATA lv_date TYPE d.
    DATA lv_time TYPE t.

    GET TIME STAMP FIELD DATA(lv_ts).
    CONVERT TIME STAMP lv_ts TIME ZONE 'UTC' INTO DATE lv_date TIME lv_time.

    DATA(lv_idx) = ( lv_date - lc_ref_monday ) MOD 7.
    IF lv_idx < 0.
      lv_idx = lv_idx + 7.
    ENDIF.

    DATA(lv_dow) = segment( val = lc_days  index = lv_idx + 1             sep = ` ` ).
    DATA(lv_mon) = segment( val = lc_month index = CONV i( lv_date+4(2) ) sep = ` ` ).

    rv = |{ lv_dow }, { lv_date+6(2) } { lv_mon } { lv_date(4) } | &&
         |{ lv_time(2) }:{ lv_time+2(2) }:{ lv_time+4(2) } GMT|.

  ENDMETHOD.

ENDCLASS.
