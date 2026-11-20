*"* use this source file for your ABAP unit test classes

CLASS ltc_blob_client DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS.

  PRIVATE SECTION.
    DATA mo_http TYPE REF TO zcl_az_http_client_mock.
    DATA mo_cut  TYPE REF TO zif_az_blob_service.

    METHODS setup.

    " ---- list containers ----
    METHODS containers_parsed_from_xml   FOR TESTING RAISING zcx_azure.
    METHODS containers_request_paging    FOR TESTING RAISING zcx_azure.
    METHODS containers_error_raises      FOR TESTING.

    " ---- list blobs ----
    METHODS blobs_parsed_with_properties FOR TESTING RAISING zcx_azure.
    METHODS blobs_request_built          FOR TESTING RAISING zcx_azure.
    METHODS blobs_prefixes_and_marker    FOR TESTING RAISING zcx_azure.
    METHODS blobs_requires_container     FOR TESTING.
    METHODS blobs_error_raises           FOR TESTING.

    " ---- download blob ----
    METHODS download_binary_content      FOR TESTING RAISING zcx_azure.
    METHODS download_textual_fallback    FOR TESTING RAISING zcx_azure.
    METHODS download_request_built       FOR TESTING RAISING zcx_azure.
    METHODS download_requires_args       FOR TESTING.
    METHODS download_error_raises        FOR TESTING.

    " ---- upload blob ----
    METHODS upload_block_blob            FOR TESTING RAISING zcx_azure.
    METHODS upload_requires_args         FOR TESTING.
    METHODS upload_error_raises          FOR TESTING.

    " ---- edge cases ----
    METHODS containers_empty              FOR TESTING RAISING zcx_azure.
    METHODS blobs_partial_properties      FOR TESTING RAISING zcx_azure.
    METHODS blobs_empty_container         FOR TESTING RAISING zcx_azure.
    METHODS blobs_special_chars_name      FOR TESTING RAISING zcx_azure.
    METHODS download_empty_blob           FOR TESTING RAISING zcx_azure.
    METHODS download_no_etag              FOR TESTING RAISING zcx_azure.
    METHODS download_content_type_charset FOR TESTING RAISING zcx_azure.
    METHODS download_image_blob           FOR TESTING RAISING zcx_azure.
    METHODS upload_empty_content          FOR TESTING RAISING zcx_azure.
    METHODS upload_default_content_type   FOR TESTING RAISING zcx_azure.
    METHODS upload_image_blob             FOR TESTING RAISING zcx_azure.
    METHODS upload_sends_version_header    FOR TESTING RAISING zcx_azure.

    " ---- SAS auth ----
    METHODS sas_appended_to_request        FOR TESTING RAISING zcx_azure.

    " ---- Shared Key auth ----
    METHODS sharedkey_signs_request        FOR TESTING RAISING zcx_azure.


    "      These cover the distinct shapes: container PUT/GET/DELETE, service-
    "      level comp query, lease action header, the array `include` param fix,
    "      x-ms-version propagation, and the generated error path) ----
    METHODS gen_container_create_puts      FOR TESTING RAISING zcx_azure.
    METHODS gen_container_delete_verb       FOR TESTING RAISING zcx_azure.
    METHODS gen_container_getproperties     FOR TESTING RAISING zcx_azure.
    METHODS gen_service_getproperties       FOR TESTING RAISING zcx_azure.
    METHODS gen_lease_action_header         FOR TESTING RAISING zcx_azure.
    METHODS gen_include_array_joined        FOR TESTING RAISING zcx_azure.
    METHODS gen_sends_version_header        FOR TESTING RAISING zcx_azure.
    METHODS gen_error_raises                FOR TESTING.
ENDCLASS.


CLASS ltc_blob_client IMPLEMENTATION.

  METHOD setup.
    mo_http = NEW zcl_az_http_client_mock( ).
    mo_cut  = NEW zcl_az_blob_client(
                iv_account_name = 'acct'
                io_credential   = NEW zcl_az_token_credential_fake( )
                io_http_client  = mo_http ).
  ENDMETHOD.

  "===================== list containers =====================

  METHOD containers_parsed_from_xml.
    mo_http->add_response(
      iv_status       = 200
      iv_content_type = 'application/xml'
      iv_body         = `<?xml version="1.0" encoding="utf-8"?>`
                     && `<EnumerationResults><Containers>`
                     && `<Container><Name>alpha</Name></Container>`
                     && `<Container><Name>beta</Name></Container>`
                     && `</Containers><NextMarker>m1</NextMarker></EnumerationResults>` ).

    DATA(lo_result) = mo_cut->list_containers( ).

    cl_abap_unit_assert=>assert_equals( exp = 2 act = lines( lo_result->mt_containers ) ).
    cl_abap_unit_assert=>assert_table_contains( line = `alpha` table = lo_result->mt_containers ).
    cl_abap_unit_assert=>assert_equals( exp = 'm1' act = lo_result->mv_next_marker ).
  ENDMETHOD.

  METHOD containers_request_paging.
    mo_http->add_response( iv_status = 200 iv_content_type = 'application/xml'
                           iv_body = `<EnumerationResults><Containers/></EnumerationResults>` ).

    mo_cut->list_containers( iv_prefix = 'log' iv_max_results = 50 iv_marker = 'mk' ).

    cl_abap_unit_assert=>assert_char_cp(
      exp = '*/?comp=list*prefix=log*maxresults=50*marker=mk*'
      act = mo_http->get_last_request( )->mv_url ).
  ENDMETHOD.

  METHOD containers_error_raises.
    mo_http->add_response( iv_status = 403 iv_content_type = 'application/xml'
                           iv_body = `<Error><Code>AuthFailed</Code></Error>` ).
    TRY.
        mo_cut->list_containers( ).
        cl_abap_unit_assert=>fail( 'expected exception for HTTP 403' ).
      CATCH zcx_azure.
    ENDTRY.
  ENDMETHOD.

  "===================== list blobs =====================

  METHOD blobs_parsed_with_properties.
    mo_http->add_response(
      iv_status       = 200
      iv_content_type = 'application/xml'
      iv_body         = `<?xml version="1.0" encoding="utf-8"?>`
                     && `<EnumerationResults><Blobs>`
                     && `<Blob><Name>docs/a.txt</Name><Properties>`
                     && `<Content-Length>1024</Content-Length>`
                     && `<Content-Type>text/plain</Content-Type>`
                     && `<Etag>0x1</Etag><BlobType>BlockBlob</BlobType>`
                     && `</Properties></Blob>`
                     && `<Blob><Name>b.bin</Name><Properties>`
                     && `<Content-Length>2048</Content-Length>`
                     && `<Content-Type>application/octet-stream</Content-Type>`
                     && `</Properties></Blob>`
                     && `</Blobs><NextMarker>mark2</NextMarker></EnumerationResults>` ).

    DATA(lo_result) = mo_cut->list_blobs( iv_container = 'c1' ).

    cl_abap_unit_assert=>assert_equals( exp = 2 act = lines( lo_result->mt_blobs ) ).
    cl_abap_unit_assert=>assert_equals( exp = 'docs/a.txt' act = lo_result->mt_blobs[ 1 ]-name ).
    cl_abap_unit_assert=>assert_equals( exp = 1024        act = lo_result->mt_blobs[ 1 ]-content_length ).
    cl_abap_unit_assert=>assert_equals( exp = 'text/plain' act = lo_result->mt_blobs[ 1 ]-content_type ).
    cl_abap_unit_assert=>assert_equals( exp = 'BlockBlob'  act = lo_result->mt_blobs[ 1 ]-blob_type ).
    cl_abap_unit_assert=>assert_equals( exp = 'b.bin'     act = lo_result->mt_blobs[ 2 ]-name ).
    cl_abap_unit_assert=>assert_equals( exp = 2048        act = lo_result->mt_blobs[ 2 ]-content_length ).
    cl_abap_unit_assert=>assert_equals( exp = 'mark2'     act = lo_result->mv_next_marker ).
  ENDMETHOD.

  METHOD blobs_request_built.
    mo_http->add_response( iv_status = 200 iv_content_type = 'application/xml'
                           iv_body = `<EnumerationResults><Blobs/></EnumerationResults>` ).

    mo_cut->list_blobs( iv_container = 'cont' iv_prefix = 'p/' iv_delimiter = '/' ).

    DATA(lo_req) = mo_http->get_last_request( ).
    cl_abap_unit_assert=>assert_equals( exp = 'GET' act = lo_req->mv_method ).
    cl_abap_unit_assert=>assert_char_cp(
      exp = '*/cont?restype=container&comp=list*prefix=p/*delimiter=/*'
      act = lo_req->mv_url ).
    READ TABLE lo_req->mt_headers WITH KEY table_line = 'x-ms-version:2023-11-03' TRANSPORTING NO FIELDS.
    cl_abap_unit_assert=>assert_subrc( msg = 'x-ms-version header missing' ).
  ENDMETHOD.

  METHOD blobs_prefixes_and_marker.
    mo_http->add_response(
      iv_status       = 200
      iv_content_type = 'application/xml'
      iv_body         = `<EnumerationResults><Blobs>`
                     && `<BlobPrefix><Name>dir1/</Name></BlobPrefix>`
                     && `<BlobPrefix><Name>dir2/</Name></BlobPrefix>`
                     && `</Blobs><NextMarker>nm</NextMarker></EnumerationResults>` ).

    DATA(lo_result) = mo_cut->list_blobs( iv_container = 'c' iv_delimiter = '/' ).

    cl_abap_unit_assert=>assert_equals( exp = 0 act = lines( lo_result->mt_blobs ) ).
    cl_abap_unit_assert=>assert_equals( exp = 2 act = lines( lo_result->mt_prefixes ) ).
    cl_abap_unit_assert=>assert_table_contains( line = `dir1/` table = lo_result->mt_prefixes ).
    cl_abap_unit_assert=>assert_equals( exp = 'nm' act = lo_result->mv_next_marker ).
  ENDMETHOD.

  METHOD blobs_requires_container.
    TRY.
        mo_cut->list_blobs( iv_container = '' ).
        cl_abap_unit_assert=>fail( 'expected exception for empty container' ).
      CATCH zcx_azure.
    ENDTRY.
    cl_abap_unit_assert=>assert_equals( exp = 0 act = mo_http->get_call_count( ) ).
  ENDMETHOD.

  METHOD blobs_error_raises.
    mo_http->add_response( iv_status = 404 iv_content_type = 'application/xml'
                           iv_body = `<Error><Code>ContainerNotFound</Code></Error>` ).
    TRY.
        mo_cut->list_blobs( iv_container = 'missing' ).
        cl_abap_unit_assert=>fail( 'expected exception for HTTP 404' ).
      CATCH zcx_azure.
    ENDTRY.
  ENDMETHOD.

  "===================== download blob =====================

  METHOD download_binary_content.
    DATA lv_bin TYPE xstring VALUE '48656C6C6F'.       " "Hello"
    mo_http->add_response(
      iv_status       = 200
      iv_content_type = 'application/octet-stream'
      iv_body_bin     = lv_bin
      it_headers      = VALUE #( ( `ETag:0xABC` ) ( `Content-Length:5` ) ) ).

    DATA(lo_content) = mo_cut->download_blob( iv_container = 'c' iv_blob_name = 'b.bin' ).

    cl_abap_unit_assert=>assert_equals( exp = lv_bin act = lo_content->mv_content ).
    cl_abap_unit_assert=>assert_equals( exp = 'application/octet-stream' act = lo_content->mv_content_type ).
    cl_abap_unit_assert=>assert_equals( exp = '0xABC' act = lo_content->mv_etag ).
    cl_abap_unit_assert=>assert_equals( exp = 5 act = lo_content->mv_content_length ).
  ENDMETHOD.

  METHOD download_textual_fallback.
    mo_http->add_response(
      iv_status       = 200
      iv_content_type = 'text/plain'
      iv_body         = `plain text` ).

    DATA(lo_content) = mo_cut->download_blob( iv_container = 'c' iv_blob_name = 'a.txt' ).

    DATA(lv_expected) = cl_abap_conv_codepage=>create_out( codepage = 'UTF-8' )->convert( `plain text` ).
    cl_abap_unit_assert=>assert_equals( exp = lv_expected act = lo_content->mv_content ).
    cl_abap_unit_assert=>assert_equals( exp = 'text/plain' act = lo_content->mv_content_type ).
  ENDMETHOD.

  METHOD download_request_built.
    DATA lv_bin TYPE xstring VALUE '00'.
    mo_http->add_response( iv_status = 200 iv_content_type = 'application/octet-stream' iv_body_bin = lv_bin ).

    mo_cut->download_blob( iv_container = 'cont' iv_blob_name = 'dir/file.dat' ).

    DATA(lo_req) = mo_http->get_last_request( ).
    cl_abap_unit_assert=>assert_equals( exp = 'GET' act = lo_req->mv_method ).
    cl_abap_unit_assert=>assert_char_cp(
      exp = '*acct.blob.core.windows.net/cont/dir/file.dat*' act = lo_req->mv_url ).
  ENDMETHOD.

  METHOD download_requires_args.
    TRY.
        mo_cut->download_blob( iv_container = 'c' iv_blob_name = '' ).
        cl_abap_unit_assert=>fail( 'expected exception for empty blob name' ).
      CATCH zcx_azure.
    ENDTRY.
    cl_abap_unit_assert=>assert_equals( exp = 0 act = mo_http->get_call_count( ) ).
  ENDMETHOD.

  METHOD download_error_raises.
    mo_http->add_response( iv_status = 404 iv_content_type = 'application/xml'
                           iv_body = `<Error><Code>BlobNotFound</Code></Error>` ).
    TRY.
        mo_cut->download_blob( iv_container = 'c' iv_blob_name = 'gone.bin' ).
        cl_abap_unit_assert=>fail( 'expected exception for HTTP 404' ).
      CATCH zcx_azure.
    ENDTRY.
  ENDMETHOD.

  "===================== upload blob =====================

  METHOD upload_block_blob.
    DATA lv_content TYPE xstring VALUE '7B7D'.          " "{}"
    mo_http->add_response(
      iv_status       = 201
      iv_content_type = ''
      it_headers      = VALUE #( ( `ETag:0xUP` ) ) ).

    DATA(lo_result) = mo_cut->upload_blob(
      iv_container    = 'c'
      iv_blob_name    = 'n.json'
      iv_content      = lv_content
      iv_content_type = 'application/json' ).

    cl_abap_unit_assert=>assert_equals( exp = '0xUP' act = lo_result->mv_etag ).

    DATA(lo_req) = mo_http->get_last_request( ).
    cl_abap_unit_assert=>assert_equals( exp = 'PUT'      act = lo_req->mv_method ).
    cl_abap_unit_assert=>assert_equals( exp = lv_content act = lo_req->mv_body_bin ).
    READ TABLE lo_req->mt_headers WITH KEY table_line = 'x-ms-blob-type:BlockBlob' TRANSPORTING NO FIELDS.
    cl_abap_unit_assert=>assert_subrc( msg = 'x-ms-blob-type header missing' ).
    READ TABLE lo_req->mt_headers WITH KEY table_line = 'Content-Type:application/json' TRANSPORTING NO FIELDS.
    cl_abap_unit_assert=>assert_subrc( msg = 'Content-Type header missing' ).
  ENDMETHOD.

  METHOD upload_requires_args.
    DATA lv_content TYPE xstring VALUE '00'.
    TRY.
        mo_cut->upload_blob( iv_container = '' iv_blob_name = 'x' iv_content = lv_content ).
        cl_abap_unit_assert=>fail( 'expected exception for empty container' ).
      CATCH zcx_azure.
    ENDTRY.
    cl_abap_unit_assert=>assert_equals( exp = 0 act = mo_http->get_call_count( ) ).
  ENDMETHOD.

  METHOD upload_error_raises.
    DATA lv_content TYPE xstring VALUE '00'.
    mo_http->add_response( iv_status = 403 iv_content_type = 'application/xml'
                           iv_body = `<Error><Code>AuthorizationFailure</Code></Error>` ).
    TRY.
        mo_cut->upload_blob( iv_container = 'c' iv_blob_name = 'n' iv_content = lv_content ).
        cl_abap_unit_assert=>fail( 'expected exception for HTTP 403' ).
      CATCH zcx_azure.
    ENDTRY.
  ENDMETHOD.

  "===================== edge cases =====================

  " list_containers: empty account -> empty result, empty marker, no error.
  METHOD containers_empty.
    mo_http->add_response( iv_status = 200 iv_content_type = 'application/xml'
      iv_body = `<EnumerationResults><Containers/><NextMarker/></EnumerationResults>` ).
    DATA(lo) = mo_cut->list_containers( ).
    cl_abap_unit_assert=>assert_initial( lo->mt_containers ).
    cl_abap_unit_assert=>assert_initial( lo->mv_next_marker ).
  ENDMETHOD.

  " list_blobs: a blob with no <Properties> -> name set, size 0, type blank.
  METHOD blobs_partial_properties.
    mo_http->add_response( iv_status = 200 iv_content_type = 'application/xml'
      iv_body = `<EnumerationResults><Blobs>`
             && `<Blob><Name>bare.txt</Name></Blob>`
             && `</Blobs></EnumerationResults>` ).
    DATA(lo) = mo_cut->list_blobs( iv_container = 'c' ).
    cl_abap_unit_assert=>assert_equals( exp = 1 act = lines( lo->mt_blobs ) ).
    cl_abap_unit_assert=>assert_equals( exp = 'bare.txt' act = lo->mt_blobs[ 1 ]-name ).
    cl_abap_unit_assert=>assert_equals( exp = 0 act = lo->mt_blobs[ 1 ]-content_length ).
    cl_abap_unit_assert=>assert_initial( lo->mt_blobs[ 1 ]-content_type ).
  ENDMETHOD.

  " list_blobs: empty container -> no blobs, no prefixes.
  METHOD blobs_empty_container.
    mo_http->add_response( iv_status = 200 iv_content_type = 'application/xml'
      iv_body = `<EnumerationResults><Blobs/></EnumerationResults>` ).
    DATA(lo) = mo_cut->list_blobs( iv_container = 'c' ).
    cl_abap_unit_assert=>assert_initial( lo->mt_blobs ).
    cl_abap_unit_assert=>assert_initial( lo->mt_prefixes ).
  ENDMETHOD.

  " list_blobs: blob names with slashes/spaces are preserved verbatim.
  METHOD blobs_special_chars_name.
    mo_http->add_response( iv_status = 200 iv_content_type = 'application/xml'
      iv_body = `<EnumerationResults><Blobs>`
             && `<Blob><Name>dir/sub/my file.txt</Name></Blob>`
             && `</Blobs></EnumerationResults>` ).
    DATA(lo) = mo_cut->list_blobs( iv_container = 'c' ).
    cl_abap_unit_assert=>assert_equals( exp = 'dir/sub/my file.txt' act = lo->mt_blobs[ 1 ]-name ).
  ENDMETHOD.

  " download: a 0-byte blob -> empty content, no error.
  METHOD download_empty_blob.
    mo_http->add_response( iv_status = 200 iv_content_type = 'application/octet-stream' ).
    DATA(lo) = mo_cut->download_blob( iv_container = 'c' iv_blob_name = 'empty.bin' ).
    cl_abap_unit_assert=>assert_initial( lo->mv_content ).
  ENDMETHOD.

  " download: response without an ETag header -> blank etag (still returns bytes).
  METHOD download_no_etag.
    DATA lv_bin TYPE xstring VALUE 'ABCD'.
    mo_http->add_response( iv_status = 200 iv_content_type = 'application/octet-stream' iv_body_bin = lv_bin ).
    DATA(lo) = mo_cut->download_blob( iv_container = 'c' iv_blob_name = 'b.bin' ).
    cl_abap_unit_assert=>assert_equals( exp = lv_bin act = lo->mv_content ).
    cl_abap_unit_assert=>assert_initial( lo->mv_etag ).
  ENDMETHOD.

  " download: Content-Type with a charset suffix is captured intact.
  METHOD download_content_type_charset.
    mo_http->add_response( iv_status = 200 iv_content_type = 'text/plain; charset=utf-8' iv_body = `hi` ).
    DATA(lo) = mo_cut->download_blob( iv_container = 'c' iv_blob_name = 'a.txt' ).
    cl_abap_unit_assert=>assert_equals( exp = 'text/plain; charset=utf-8' act = lo->mv_content_type ).
  ENDMETHOD.

  " upload: a 0-byte blob is still a valid PUT (empty body).
  METHOD upload_empty_content.
    DATA lv_empty TYPE xstring.
    mo_http->add_response( iv_status = 201 iv_content_type = '' ).
    mo_cut->upload_blob( iv_container = 'c' iv_blob_name = 'zero.bin' iv_content = lv_empty ).
    DATA(lo_req) = mo_http->get_last_request( ).
    cl_abap_unit_assert=>assert_equals( exp = 'PUT' act = lo_req->mv_method ).
    cl_abap_unit_assert=>assert_initial( lo_req->mv_body_bin ).
  ENDMETHOD.

  " upload: omitting the content type defaults to application/octet-stream.
  METHOD upload_default_content_type.
    DATA lv_bin TYPE xstring VALUE '00'.
    mo_http->add_response( iv_status = 201 iv_content_type = '' ).
    mo_cut->upload_blob( iv_container = 'c' iv_blob_name = 'x.bin' iv_content = lv_bin ).
    DATA(lo_req) = mo_http->get_last_request( ).
    READ TABLE lo_req->mt_headers
      WITH KEY table_line = 'Content-Type:application/octet-stream' TRANSPORTING NO FIELDS.
    cl_abap_unit_assert=>assert_subrc( msg = 'default content-type not applied' ).
  ENDMETHOD.

  " download: an image/* response is treated as binary (not text-decoded) -
  " the raw xstring bytes survive intact and the image content-type is kept.
  METHOD download_image_blob.
    " 1x1 transparent PNG header bytes (enough to assert byte-exact transport)
    DATA lv_png TYPE xstring VALUE '89504E470D0A1A0A0000000D49484452'.
    mo_http->add_response(
      iv_status       = 200
      iv_content_type = 'image/png'
      iv_body_bin     = lv_png
      it_headers      = VALUE #( ( `ETag:0xIMG` ) ( `Content-Length:16` ) ) ).

    DATA(lo_content) = mo_cut->download_blob( iv_container = 'c' iv_blob_name = 'pic.png' ).

    cl_abap_unit_assert=>assert_equals( exp = lv_png       act = lo_content->mv_content ).
    cl_abap_unit_assert=>assert_equals( exp = 'image/png'  act = lo_content->mv_content_type ).
    cl_abap_unit_assert=>assert_equals( exp = '0xIMG'      act = lo_content->mv_etag ).
    cl_abap_unit_assert=>assert_equals( exp = 16           act = lo_content->mv_content_length ).
  ENDMETHOD.

  " upload: an image blob is sent as a binary PUT with the image content-type
  " header and the raw bytes in mv_body_bin (no text encoding).
  METHOD upload_image_blob.
    DATA lv_jpg TYPE xstring VALUE 'FFD8FFE000104A464946'.   " JPEG SOI + APP0 marker
    mo_http->add_response(
      iv_status       = 201
      iv_content_type = ''
      it_headers      = VALUE #( ( `ETag:0xJPG` ) ) ).

    DATA(lo_result) = mo_cut->upload_blob(
      iv_container    = 'c'
      iv_blob_name    = 'photo.jpg'
      iv_content      = lv_jpg
      iv_content_type = 'image/jpeg' ).

    cl_abap_unit_assert=>assert_equals( exp = '0xJPG' act = lo_result->mv_etag ).

    DATA(lo_req) = mo_http->get_last_request( ).
    cl_abap_unit_assert=>assert_equals( exp = 'PUT'    act = lo_req->mv_method ).
    cl_abap_unit_assert=>assert_equals( exp = lv_jpg   act = lo_req->mv_body_bin ).
    READ TABLE lo_req->mt_headers
      WITH KEY table_line = 'Content-Type:image/jpeg' TRANSPORTING NO FIELDS.
    cl_abap_unit_assert=>assert_subrc( msg = 'image/jpeg content-type header missing' ).
  ENDMETHOD.

  " every request carries the x-ms-version header.
  METHOD upload_sends_version_header.
    DATA lv_bin TYPE xstring VALUE '00'.
    mo_http->add_response( iv_status = 201 iv_content_type = '' ).
    mo_cut->upload_blob( iv_container = 'c' iv_blob_name = 'x.bin' iv_content = lv_bin ).
    DATA(lo_req) = mo_http->get_last_request( ).
    READ TABLE lo_req->mt_headers
      WITH KEY table_line = 'x-ms-version:2023-11-03' TRANSPORTING NO FIELDS.
    cl_abap_unit_assert=>assert_subrc( msg = 'x-ms-version header missing' ).
  ENDMETHOD.

  " a SAS-configured client (iv_sas_token) appends the SAS query string to the
  " request URL via zcl_az_policy_sas, and uses no AAD credential.
  METHOD sas_appended_to_request.
    DATA(lo_http) = NEW zcl_az_http_client_mock( ).
    DATA(lo_cut)  = NEW zcl_az_blob_client(
                      iv_account_name = 'acct'
                      iv_sas_token    = 'sv=2023-11-03&sig=abc'
                      io_http_client  = lo_http ).
    lo_http->add_response( iv_status = 200 iv_content_type = 'application/xml'
      iv_body = `<EnumerationResults><Containers/></EnumerationResults>` ).

    lo_cut->list_containers( ).

    cl_abap_unit_assert=>assert_char_cp(
      exp = '*comp=list&sv=2023-11-03&sig=abc'
      act = lo_http->get_last_request( )->mv_url ).
  ENDMETHOD.

  " a Shared-Key-configured client (iv_account_key) signs each request with an
  " "Authorization: SharedKey <account>:<signature>" header via
  " zcl_az_policy_shared_key, and uses no AAD credential.
  METHOD sharedkey_signs_request.
    DATA(lo_http) = NEW zcl_az_http_client_mock( ).
    DATA(lo_cut)  = NEW zcl_az_blob_client(
                      iv_account_name = 'acct'
                      iv_account_key  = 'a2V5'
                      io_http_client  = lo_http ).
    lo_http->add_response( iv_status = 200 iv_content_type = 'application/xml'
      iv_body = `<EnumerationResults><Containers/></EnumerationResults>` ).

    lo_cut->list_containers( ).

    DATA(lo_req)   = lo_http->get_last_request( ).
    DATA lv_found TYPE abap_bool.
    LOOP AT lo_req->mt_headers INTO DATA(lv_h).
      IF lv_h CP 'Authorization: SharedKey acct:*'.
        lv_found = abap_true.
      ENDIF.
    ENDLOOP.
    cl_abap_unit_assert=>assert_true(
      act = lv_found
      msg = 'Shared Key policy must add an Authorization: SharedKey header' ).
  ENDMETHOD.



  " container_create: PUT to /{container} with the restype=container marker.
  METHOD gen_container_create_puts.
    mo_http->add_response( iv_status = 201 iv_content_type = '' ).

    mo_cut->container_create(
      restype = 'container' container_name = 'c1' x_ms_version = '2023-11-03' ).

    DATA(lo_req) = mo_http->get_last_request( ).
    cl_abap_unit_assert=>assert_equals( exp = 'PUT' act = lo_req->mv_method ).
    cl_abap_unit_assert=>assert_char_cp( exp = '*/c1?restype=container*' act = lo_req->mv_url ).
  ENDMETHOD.

  " container_delete: DELETE verb on the container resource.
  METHOD gen_container_delete_verb.
    mo_http->add_response( iv_status = 202 iv_content_type = '' ).

    mo_cut->container_delete(
      restype = 'container' container_name = 'c1' x_ms_version = '2023-11-03' ).

    DATA(lo_req) = mo_http->get_last_request( ).
    cl_abap_unit_assert=>assert_equals( exp = 'DELETE' act = lo_req->mv_method ).
    cl_abap_unit_assert=>assert_char_cp( exp = '*/c1?restype=container*' act = lo_req->mv_url ).
  ENDMETHOD.

  " container_getproperties: GET with the restype=container query.
  METHOD gen_container_getproperties.
    mo_http->add_response( iv_status = 200 iv_content_type = 'application/xml' iv_body = `<x/>` ).

    DATA(ls) = mo_cut->container_getproperties(
      restype = 'container' container_name = 'c1' x_ms_version = '2023-11-03' ).

    DATA(lo_req) = mo_http->get_last_request( ).
    cl_abap_unit_assert=>assert_equals( exp = 'GET' act = lo_req->mv_method ).
    cl_abap_unit_assert=>assert_equals( exp = 200   act = ls-code ).
    cl_abap_unit_assert=>assert_char_cp( exp = '*restype=container*' act = lo_req->mv_url ).
  ENDMETHOD.

  " service_getproperties: account-level GET on /?restype=service&comp=properties.
  METHOD gen_service_getproperties.
    mo_http->add_response( iv_status = 200 iv_content_type = 'application/xml'
      iv_body = `<StorageServiceProperties/>` ).

    mo_cut->service_getproperties(
      restype = 'service' comp = 'properties' x_ms_version = '2023-11-03' ).

    DATA(lv_url) = mo_http->get_last_request( )->mv_url.
    cl_abap_unit_assert=>assert_char_cp( exp = '*restype=service*' act = lv_url ).
    cl_abap_unit_assert=>assert_char_cp( exp = '*comp=properties*' act = lv_url ).
  ENDMETHOD.

  " container_acquirelease: PUT lease op carrying the x-ms-lease-action header.
  METHOD gen_lease_action_header.
    mo_http->add_response( iv_status = 201 iv_content_type = '' ).

    mo_cut->container_acquirelease(
      comp = 'lease' restype = 'container' x_ms_lease_action = 'acquire'
      container_name = 'c1' x_ms_version = '2023-11-03' ).

    DATA(lo_req) = mo_http->get_last_request( ).
    cl_abap_unit_assert=>assert_equals( exp = 'PUT' act = lo_req->mv_method ).
    READ TABLE lo_req->mt_headers
      WITH KEY table_line = 'x-ms-lease-action:acquire' TRANSPORTING NO FIELDS.
    cl_abap_unit_assert=>assert_subrc( msg = 'x-ms-lease-action header not propagated' ).
  ENDMETHOD.

  " the array `include` query param must be comma-joined (generator fix),
  " not dropped into the URL as a table -> regression guard.
  METHOD gen_include_array_joined.
    mo_http->add_response( iv_status = 200 iv_content_type = 'application/xml'
      iv_body = `<EnumerationResults/>` ).

    mo_cut->container_listblobflatsegmen(
      restype = 'container' comp = 'list' container_name = 'c1'
      include = VALUE string_table( ( `metadata` ) ( `snapshots` ) )
      x_ms_version = '2023-11-03' ).

    cl_abap_unit_assert=>assert_char_cp(
      exp = '*include=metadata,snapshots*'
      act = mo_http->get_last_request( )->mv_url
      msg = 'array include param not comma-joined' ).
  ENDMETHOD.

  " a generated op propagates the x-ms-version header it was given.
  METHOD gen_sends_version_header.
    mo_http->add_response( iv_status = 201 iv_content_type = '' ).

    mo_cut->container_create(
      restype = 'container' container_name = 'c1' x_ms_version = '2021-12-02' ).

    READ TABLE mo_http->get_last_request( )->mt_headers
      WITH KEY table_line = 'x-ms-version:2021-12-02' TRANSPORTING NO FIELDS.
    cl_abap_unit_assert=>assert_subrc( msg = 'x-ms-version header missing on generated op' ).
  ENDMETHOD.

  " a non-2xx on a generated op surfaces as a typed zcx_azure (retry-exhausted).
  METHOD gen_error_raises.
    mo_http->add_response( iv_status = 404 iv_content_type = 'application/xml'
      iv_body = `<Error><Code>ContainerNotFound</Code></Error>` ).

    TRY.
        mo_cut->container_getproperties(
          restype = 'container' container_name = 'gone' x_ms_version = '2023-11-03' ).
        cl_abap_unit_assert=>fail( 'expected zcx_azure for HTTP 404' ).
      CATCH zcx_azure.
    ENDTRY.
  ENDMETHOD.

ENDCLASS.


"======================================================================
" Managed Identity -> blob path (offline). Two mocks: one backs the MI
" credential (IMDS), one backs the blob client's transport. Proves the
" full chain MI credential -> auth policy -> blob request without network.
"======================================================================
CLASS ltc_blob_mi DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS.

  PRIVATE SECTION.
    "! The IMDS-issued bearer token is attached to the blob data request.
    METHODS mi_token_flows_to_blob      FOR TESTING RAISING zcx_azure.
    "! The blob client's storage scope flows through the MI credential to IMDS.
    METHODS mi_requests_storage_scope   FOR TESTING RAISING zcx_azure.
ENDCLASS.


CLASS ltc_blob_mi IMPLEMENTATION.

  METHOD mi_token_flows_to_blob.
    " credential seam: a managed-identity credential backed by an IMDS mock.
    DATA(lo_imds) = NEW zcl_az_http_client_mock( ).
    lo_imds->add_response( iv_status = 200
      iv_body = `{"access_token":"imds-mi-token","token_type":"Bearer","expires_in":3599}` ).
    DATA(lo_mi) = NEW zcl_az_managed_identity_cred( io_http_client = lo_imds ).

    " transport seam: the blob client's own transport mock.
    DATA(lo_blob_http) = NEW zcl_az_http_client_mock( ).
    lo_blob_http->add_response( iv_status = 200 iv_content_type = 'application/xml'
      iv_body = `<EnumerationResults><Blobs/></EnumerationResults>` ).

    DATA(lo_blob) = NEW zcl_az_blob_client(
      iv_account_name = 'acct'
      io_credential   = lo_mi
      io_http_client  = lo_blob_http ).

    lo_blob->list_blobs( iv_container = 'c1' ).

    " the IMDS bearer token must ride on the blob request
    READ TABLE lo_blob_http->get_last_request( )->mt_headers TRANSPORTING NO FIELDS
      WITH KEY table_line = 'Authorization: Bearer imds-mi-token'.
    cl_abap_unit_assert=>assert_subrc(
      msg = 'MI bearer token not propagated to the blob request' ).
    " and IMDS was actually contacted
    cl_abap_unit_assert=>assert_equals( exp = 1 act = lo_imds->get_call_count( ) ).
  ENDMETHOD.

  METHOD mi_requests_storage_scope.
    DATA(lo_imds) = NEW zcl_az_http_client_mock( ).
    lo_imds->add_response( iv_status = 200
      iv_body = `{"access_token":"t","token_type":"Bearer","expires_in":1}` ).
    DATA(lo_mi) = NEW zcl_az_managed_identity_cred( io_http_client = lo_imds ).

    DATA(lo_blob_http) = NEW zcl_az_http_client_mock( ).
    lo_blob_http->add_response( iv_status = 200 iv_content_type = 'application/xml'
      iv_body = `<EnumerationResults><Blobs/></EnumerationResults>` ).

    DATA(lo_blob) = NEW zcl_az_blob_client(
      iv_account_name = 'acct'
      io_credential   = lo_mi
      io_http_client  = lo_blob_http ).

    lo_blob->list_blobs( iv_container = 'c1' ).

    " the blob client's auth policy asks for the storage scope, which the MI
    " credential turns into an IMDS resource= request carrying Metadata:true.
    DATA(lo_imds_req) = lo_imds->get_last_request( ).
    cl_abap_unit_assert=>assert_char_cp(
      exp = '*resource=*storage.azure.com*'
      act = lo_imds_req->mv_url ).
    READ TABLE lo_imds_req->mt_headers TRANSPORTING NO FIELDS
      WITH KEY table_line = 'Metadata:true'.
    cl_abap_unit_assert=>assert_subrc( msg = 'IMDS Metadata:true header missing' ).
  ENDMETHOD.

ENDCLASS.


"======================================================================
" Integration tests against REAL Azure (no io_http_client -> live
" zcl_az_http_client). RISK LEVEL DANGEROUS so they only run when the
" system explicitly allows it, and each test self-skips unless a real
" storage account + credential are configured. The round-trip test
" WRITES a blob (overwrites the same name each run).
"   Setup: edit c_account / c_container below, and supply the secret via
"   zcl_az_test_environment=>get_instance( )->configure( iv_client_secret = '...' )
"   (plus client/tenant ids) in your run, or hard-code in ZCL_AZ_TEST_ENVIRONMENT.
"======================================================================
CLASS ltc_blob_integration DEFINITION FINAL FOR TESTING
  DURATION LONG
  RISK LEVEL HARMLESS.

  PRIVATE SECTION.
    CONSTANTS c_account   TYPE string VALUE ''.
    CONSTANTS c_container TYPE string VALUE ''.
    CONSTANTS c_blob      TYPE string VALUE 'sdk-roundtrip.txt'.
    CONSTANTS c_image     TYPE string VALUE 'sdk-roundtrip.png'.
    CONSTANTS c_key       TYPE string VALUE ''.
    "! Set to abap_true when running ON an Azure host with IMDS (VM/App Service)
    "! whose managed identity holds a Storage Blob Data role on c_account.
    CONSTANTS c_mi_enabled   TYPE abap_bool VALUE abap_false.
    "! Optional: client id of a user-assigned managed identity (blank = system-assigned).
    CONSTANTS c_mi_client_id TYPE string VALUE ''.

    "! SAS query string for the SAS integration tests. Returned at runtime (not a
    "! CONSTANT) because a real SAS commonly exceeds the 132-char literal limit.
    METHODS sas RETURNING VALUE(rv) TYPE string.

    DATA mo_env TYPE REF TO zcl_az_test_environment.
    DATA mo_cut TYPE REF TO zif_az_blob_service.

    METHODS setup.
    "! True only when a real account + client secret are present.
    METHODS configured RETURNING VALUE(rv) TYPE abap_bool.

    "! Read-only: list containers in the account.
    METHODS list_containers_real      FOR TESTING RAISING zcx_azure.
    "! Read-only: list blobs in the test container.
    METHODS list_blobs_real           FOR TESTING RAISING zcx_azure.
    "! Write+read: upload a blob then download it and compare the bytes.
    METHODS upload_download_roundtrip FOR TESTING RAISING zcx_azure.
    "! True only when a real account + SAS token are present.
    METHODS sas_configured RETURNING VALUE(rv) TYPE abap_bool.
    "! Read-only via SAS: list blobs with a SAS-authenticated client (no credential).
    METHODS list_blobs_sas_real       FOR TESTING RAISING zcx_azure.
    "! Write+read via SAS: upload a blob then download it and compare the bytes
    "! (needs a SAS with write+read, e.g. sp=racwdl, scoped to the container).
    METHODS upload_download_sas_real  FOR TESTING RAISING zcx_azure.
    "! True only when a real account + account key are present.
    METHODS key_configured RETURNING VALUE(rv) TYPE abap_bool.
    "! Read-only via Shared Key: list blobs with an account-key-signed client.
    METHODS list_blobs_sharedkey_real FOR TESTING RAISING zcx_azure.

    "! A small binary PNG payload for the image round-trip tests.
    METHODS png_bytes RETURNING VALUE(rv) TYPE xstring.
    "! Write+read of an image/png blob via AAD: bytes + content-type must survive.
    METHODS image_roundtrip_real      FOR TESTING RAISING zcx_azure.
    "! Write+read of an image/png blob via SAS: bytes + content-type must survive.
    METHODS image_roundtrip_sas_real  FOR TESTING RAISING zcx_azure.
    "! True only on an MI-enabled host (c_mi_enabled) with a real account.
    METHODS mi_configured RETURNING VALUE(rv) TYPE abap_bool.
    "! Read-only via Managed Identity: list blobs with the host's IMDS token
    "! (the MI must hold a Storage Blob Data role on the account).
    METHODS list_blobs_mi_real        FOR TESTING RAISING zcx_azure.
ENDCLASS.


CLASS ltc_blob_integration IMPLEMENTATION.

  METHOD setup.
    mo_env = zcl_az_test_environment=>get_instance( ).
    " no io_http_client -> the real zcl_az_http_client is used (live Azure)
    mo_cut = NEW zcl_az_blob_client(
               iv_account_name = c_account
               io_credential   = mo_env->create_credential( ) ).
  ENDMETHOD.

  METHOD configured.
    rv = boolc( c_account NP 'your-*' AND mo_env->get_client_secret( ) IS NOT INITIAL ).
  ENDMETHOD.

  METHOD list_containers_real.
    IF configured( ) = abap_false. RETURN. ENDIF.
    DATA(lo_result) = mo_cut->list_containers( ).
    cl_abap_unit_assert=>assert_bound( lo_result ).
  ENDMETHOD.

  METHOD list_blobs_real.
    IF configured( ) = abap_false. RETURN. ENDIF.
    DATA(lo_result) = mo_cut->list_blobs( iv_container = c_container ).
    cl_abap_unit_assert=>assert_bound( lo_result ).
  ENDMETHOD.

  METHOD upload_download_roundtrip.
    IF configured( ) = abap_false. RETURN. ENDIF.

DATA(lv_payload) = cl_abap_conv_codepage=>create_out( codepage = 'UTF-8'
  )->convert( |abap-sdk-azure roundtrip { xco_cp=>sy->date( )->as( xco_cp_time=>format->abap )->value }-| &&
              |{ xco_cp=>sy->time( )->as( xco_cp_time=>format->abap )->value }| ).


    DATA(lo_up) = mo_cut->upload_blob(
      iv_container    = c_container
      iv_blob_name    = c_blob
      iv_content      = lv_payload
      iv_content_type = 'text/plain' ).
    cl_abap_unit_assert=>assert_not_initial( lo_up->mv_etag ).

    DATA(lo_down) = mo_cut->download_blob(
      iv_container = c_container
      iv_blob_name = c_blob ).
    cl_abap_unit_assert=>assert_equals(
      exp = lv_payload act = lo_down->mv_content
      msg = 'downloaded bytes differ from uploaded' ).
  ENDMETHOD.

  METHOD sas.
    " Paste your SAS query string here (with or without a leading '?').
    rv = ``.
  ENDMETHOD.

  METHOD sas_configured.
    rv = boolc( c_account NP 'your-*' AND sas( ) IS NOT INITIAL ).
  ENDMETHOD.

  METHOD list_blobs_sas_real.
    IF sas_configured( ) = abap_false. RETURN. ENDIF.
    " SAS-authenticated client - no credential, no RBAC role required
    DATA(lo_sas_cut) = NEW zcl_az_blob_client(
                         iv_account_name = c_account
                         iv_sas_token    = sas( ) ).
    DATA(lo_result) = lo_sas_cut->list_blobs( iv_container = c_container ).
    cl_abap_unit_assert=>assert_bound( lo_result ).
  ENDMETHOD.

  METHOD upload_download_sas_real.
    IF sas_configured( ) = abap_false. RETURN. ENDIF.
    " SAS-authenticated write+read of c_blob (overwrites the same name each run).
    " Requires a SAS with write+read scoped to the container (e.g. sp=racwdl).
    DATA(lo_sas_cut) = NEW zcl_az_blob_client(
                         iv_account_name = c_account
                         iv_sas_token    = sas( ) ).

    DATA(lv_payload) = cl_abap_conv_codepage=>create_out( codepage = 'UTF-8'
      )->convert( |abap-sdk-azure SAS roundtrip { xco_cp=>sy->date( )->as( xco_cp_time=>format->abap )->value }-| &&
                  |{ xco_cp=>sy->time( )->as( xco_cp_time=>format->abap )->value }| ).

    DATA(lo_up) = lo_sas_cut->upload_blob(
      iv_container    = c_container
      iv_blob_name    = c_blob
      iv_content      = lv_payload
      iv_content_type = 'text/plain' ).
    cl_abap_unit_assert=>assert_not_initial( lo_up->mv_etag ).

    DATA(lo_down) = lo_sas_cut->download_blob(
      iv_container = c_container
      iv_blob_name = c_blob ).
    cl_abap_unit_assert=>assert_equals(
      exp = lv_payload act = lo_down->mv_content
      msg = 'SAS download bytes differ from uploaded' ).
  ENDMETHOD.

  METHOD key_configured.
    rv = boolc( c_account NP 'your-*' AND c_key IS NOT INITIAL ).
  ENDMETHOD.

  METHOD list_blobs_sharedkey_real.
    IF key_configured( ) = abap_false. RETURN. ENDIF.
    " Shared Key (account key) signed client - no credential, no RBAC role required
    DATA(lo_key_cut) = NEW zcl_az_blob_client(
                         iv_account_name = c_account
                         iv_account_key  = c_key ).
    DATA(lo_result) = lo_key_cut->list_blobs( iv_container = c_container ).
    cl_abap_unit_assert=>assert_bound( lo_result ).
  ENDMETHOD.

  METHOD png_bytes.
    " minimal PNG: 8-byte signature + IHDR length/type (enough to prove the
    " binary path keeps the bytes byte-exact through upload/download).
    rv = '89504E470D0A1A0A0000000D49484452'.
  ENDMETHOD.

  METHOD image_roundtrip_real.
    IF configured( ) = abap_false. RETURN. ENDIF.
    " AAD: upload an image/png blob and read it back byte-for-byte.
    DATA(lv_img) = png_bytes( ).

    DATA(lo_up) = mo_cut->upload_blob(
      iv_container    = c_container
      iv_blob_name    = c_image
      iv_content      = lv_img
      iv_content_type = 'image/png' ).
    cl_abap_unit_assert=>assert_not_initial( lo_up->mv_etag ).

    DATA(lo_down) = mo_cut->download_blob(
      iv_container = c_container
      iv_blob_name = c_image ).
    cl_abap_unit_assert=>assert_equals(
      exp = lv_img act = lo_down->mv_content
      msg = 'image bytes differ after AAD round-trip' ).
    cl_abap_unit_assert=>assert_equals(
      exp = 'image/png' act = lo_down->mv_content_type
      msg = 'image content-type not preserved (AAD)' ).
  ENDMETHOD.

  METHOD image_roundtrip_sas_real.
    IF sas_configured( ) = abap_false. RETURN. ENDIF.
    " SAS: upload an image/png blob and read it back byte-for-byte.
    " Needs a SAS with write+read scoped to the container (e.g. sp=racwdl).
    DATA(lo_sas_cut) = NEW zcl_az_blob_client(
                         iv_account_name = c_account
                         iv_sas_token    = sas( ) ).
    DATA(lv_img) = png_bytes( ).

    DATA(lo_up) = lo_sas_cut->upload_blob(
      iv_container    = c_container
      iv_blob_name    = c_image
      iv_content      = lv_img
      iv_content_type = 'image/png' ).
    cl_abap_unit_assert=>assert_not_initial( lo_up->mv_etag ).

    DATA(lo_down) = lo_sas_cut->download_blob(
      iv_container = c_container
      iv_blob_name = c_image ).
    cl_abap_unit_assert=>assert_equals(
      exp = lv_img act = lo_down->mv_content
      msg = 'image bytes differ after SAS round-trip' ).
    cl_abap_unit_assert=>assert_equals(
      exp = 'image/png' act = lo_down->mv_content_type
      msg = 'image content-type not preserved (SAS)' ).
  ENDMETHOD.

  METHOD mi_configured.
    rv = boolc( c_account NP 'your-*' AND c_mi_enabled = abap_true ).
  ENDMETHOD.

  METHOD list_blobs_mi_real.
    IF mi_configured( ) = abap_false. RETURN. ENDIF.
    " Managed identity: no secret / no SAS - the host's IMDS endpoint issues the
    " token. The MI must hold a Storage Blob Data (Reader/Contributor) role on the
    " account, or Azure returns 403 AuthorizationPermissionMismatch.
    DATA(lo_mi) = NEW zcl_az_managed_identity_cred( ).
    IF c_mi_client_id IS NOT INITIAL.
      lo_mi->set_client_id( c_mi_client_id ).
    ENDIF.
    DATA(lo_mi_cut) = NEW zcl_az_blob_client(
      iv_account_name = c_account
      io_credential   = lo_mi ).

    DATA(lo_result) = lo_mi_cut->list_blobs( iv_container = c_container ).
    cl_abap_unit_assert=>assert_bound( lo_result ).
  ENDMETHOD.

ENDCLASS.
