* Copyright (c) Microsoft Corporation.
* Licensed under the MIT license.

CLASS zcl_az_blob_content DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.

    "! Downloaded blob payload + key metadata.
    DATA mv_content        TYPE xstring.
    DATA mv_content_type   TYPE string.
    DATA mv_content_length TYPE i.
    DATA mv_etag           TYPE string.
    DATA mv_last_modified  TYPE string.

  PROTECTED SECTION.
  PRIVATE SECTION.
ENDCLASS.



CLASS zcl_az_blob_content IMPLEMENTATION.
ENDCLASS.
