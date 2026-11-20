*"* use this source file for your ABAP unit test classes
*"* use this source file for your ABAP unit test classes

CLASS ltc_crypto DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS.

  PRIVATE SECTION.
    " RFC 4231 HMAC-SHA256 Test Case 1: key = 20 bytes of 0x0b, data = "Hi There".
    " Key as base64 (20 x 0x0b) and the expected signature as base64.
    CONSTANTS c_rfc_key TYPE string VALUE 'CwsLCwsLCwsLCwsLCwsLCwsLCws='.
    CONSTANTS c_rfc_sig TYPE string VALUE 'sDRMYdjbOFNcqK/OrwvxK4gdwgDJgz2nJuk3bC4yz/c='.

    "! Known-answer test against the RFC 4231 vector.
    METHODS matches_rfc4231_vector    FOR TESTING RAISING zcx_az_serialization_error.
    "! Same inputs always yield the same signature.
    METHODS is_deterministic          FOR TESTING RAISING zcx_az_serialization_error.
    "! A different key yields a different signature.
    METHODS different_key_differs     FOR TESTING RAISING zcx_az_serialization_error.
    "! Output is a 44-char base64 SHA256 digest (32 bytes -> 44 chars, '=' padded).
    METHODS output_is_base64_sha256   FOR TESTING RAISING zcx_az_serialization_error.

ENDCLASS.


CLASS ltc_crypto IMPLEMENTATION.

  METHOD matches_rfc4231_vector.
    cl_abap_unit_assert=>assert_equals(
      exp = c_rfc_sig
      act = zcl_az_crypto=>hmac_sha256_b64( iv_key_base64 = c_rfc_key iv_data = 'Hi There' ) ).
  ENDMETHOD.

  METHOD is_deterministic.
    cl_abap_unit_assert=>assert_equals(
      exp = zcl_az_crypto=>hmac_sha256_b64( iv_key_base64 = c_rfc_key iv_data = 'payload' )
      act = zcl_az_crypto=>hmac_sha256_b64( iv_key_base64 = c_rfc_key iv_data = 'payload' ) ).
  ENDMETHOD.

  METHOD different_key_differs.
    cl_abap_unit_assert=>assert_differs(
      exp = zcl_az_crypto=>hmac_sha256_b64( iv_key_base64 = c_rfc_key iv_data = 'payload' )
      act = zcl_az_crypto=>hmac_sha256_b64( iv_key_base64 = 'YWJjZGVm' iv_data = 'payload' ) ).
  ENDMETHOD.

  METHOD output_is_base64_sha256.
    DATA(lv_sig) = zcl_az_crypto=>hmac_sha256_b64( iv_key_base64 = c_rfc_key iv_data = 'x' ).
    cl_abap_unit_assert=>assert_equals( exp = 44 act = strlen( lv_sig ) ).
    cl_abap_unit_assert=>assert_char_cp( exp = '*=' act = lv_sig ).
  ENDMETHOD.

ENDCLASS.
