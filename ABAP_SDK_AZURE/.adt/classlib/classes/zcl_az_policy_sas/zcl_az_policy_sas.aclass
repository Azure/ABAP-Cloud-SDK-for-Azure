* Copyright (c) Microsoft Corporation.
* Licensed under the MIT license.

CLASS zcl_az_policy_sas DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.

    "! Pipeline policy that authenticates storage requests with a Shared Access
    "! Signature (SAS). Unlike AAD auth, a SAS is NOT a bearer token: it is a
    "! signed query string that must be appended to the request URL. Use this
    "! policy in place of zcl_az_policy_auth when authenticating with a SAS.
    INTERFACES zif_az_http_pipeline_policy.

    METHODS constructor
      IMPORTING
        iv_sas_token TYPE string.

  PRIVATE SECTION.

    DATA mv_sas_token TYPE string.

ENDCLASS.



CLASS zcl_az_policy_sas IMPLEMENTATION.

  METHOD constructor.
    mv_sas_token = iv_sas_token.
    " Accept the SAS with or without a leading '?'.
    IF strlen( mv_sas_token ) > 0 AND mv_sas_token(1) = '?'.
      mv_sas_token = mv_sas_token+1.
    ENDIF.
  ENDMETHOD.

  METHOD zif_az_http_pipeline_policy~process.

    " Guard: required inputs must be bound
    IF io_context IS INITIAL OR io_request IS INITIAL.
      RAISE EXCEPTION TYPE zcx_az_http_error
        EXPORTING
          iv_status_code = 0
          iv_message     = |Invalid request: context or request is not bound.|.
    ENDIF.

    " Append the SAS query string to the request URL (using '&' if the URL
    " already carries query parameters such as ?comp=list, otherwise '?').
    IF mv_sas_token IS NOT INITIAL.
      io_request->mv_url = io_request->mv_url &&
        COND string( WHEN io_request->mv_url CS '?' THEN '&' ELSE '?' ) &&
        mv_sas_token.
    ENDIF.

    " A SAS carries the signature in the URL, so no Authorization header is set.
    ro_response = io_context->next( io_request ).

  ENDMETHOD.

ENDCLASS.
