package ravensight
import "core:strings"
import "core:testing"
REPORT_TEST_PNG :: "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00"
Report_Recorded :: struct {status,reason:string, calls:int,}
report_record :: proc(user:rawptr,status,reason:string) {
 r:=(^Report_Recorded)(user);r.status=status=="complete" ? "complete" : status=="processing" ? "processing" : "";r.reason=reason;r.calls+=1
}
@(test)
test_report_consent_and_png_validation :: proc(t:^testing.T) {
 input:=Report_Input{client_id="fixture-001",message="Bug",png=transmute([]u8)string(REPORT_TEST_PNG)}
 r,reason:=create_report(input);testing.expect(t,r==nil && reason=="report_consent_required")
 input.consent=true;input.png=transmute([]u8)string("bad");r,reason=create_report(input);testing.expect(t,r==nil && reason=="invalid_report")
 input.png=transmute([]u8)string(REPORT_TEST_PNG);r,reason=create_report(input);testing.expect(t,r!=nil && reason=="");testing.expect(t,strings.contains(r.payload,`"sha256":"`));testing.expect(t,destroy_report(r))
}
@(test)
test_report_upload_binary_session_and_replay :: proc(t:^testing.T) {
 f:Fake;fake_init(&f);defer fake_destroy(&f)
 cl:=fake_client(t,&f,Config{disable_lifecycle_events=true});defer close_client(cl);core_want_session(&cl.core);boot_client(t,&f,cl)
 r,_:=create_report(Report_Input{client_id="fixture-001",message="Bug",png=transmute([]u8)string(REPORT_TEST_PNG),consent=true});defer destroy_report(r)
 recorded:Report_Recorded
 testing.expect(t,submit_report(cl,r,report_record,&recorded));testing.expect(t,!submit_report(cl,r,report_record,&recorded));testing.expect(t,!destroy_report(r))
 idx:=open_request(&f);testing.expect(t,has_header(f.requests[idx],"X-Session-Token: tok_1"))
 answer_next(t,&f,"/reports",201,`{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","status":"pending"}`)
 answer_next(t,&f,"/reports/aaaaaaaaaaaaaaaaaaaaaaaa/upload",200,`{"url":"https://upload.example.com/","fields":{"key":"fixture","Policy":"signed"}}`)
 idx=open_request(&f);upload:=f.requests[idx]
 testing.expect(t,strings.contains(upload.body,REPORT_TEST_PNG));testing.expect(t,!has_header(upload,"X-Session-Token: tok_1"));testing.expect(t,len(upload.headers)==1)
 answer(&f,idx,204)
 answer_next(t,&f,"/reports/aaaaaaaaaaaaaaaaaaaaaaaa/finalize",202,`{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","status":"processing"}`)
 testing.expect(t,recorded.status=="processing" && recorded.calls==1)
 testing.expect(t,submit_report(cl,r,report_record,&recorded))
 idx=open_request(&f);testing.expect(t,f.requests[idx].body=="")
 answer_next(t,&f,"/reports/aaaaaaaaaaaaaaaaaaaaaaaa",200,`{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","status":"complete"}`)
 testing.expect(t,recorded.status=="complete" && recorded.calls==2)
 testing.expect_value(t,queue_len(cl),0)
}
@(test)
test_report_ambiguous_retry_and_session_fence :: proc(t:^testing.T) {
 f:Fake;fake_init(&f);defer fake_destroy(&f)
 cl:=fake_client(t,&f,Config{disable_lifecycle_events=true});defer close_client(cl);core_want_session(&cl.core);boot_client(t,&f,cl)
 r,_:=create_report(Report_Input{client_id="fixture-002",message="Bug",png=transmute([]u8)string(REPORT_TEST_PNG),consent=true});defer destroy_report(r)
 recorded:Report_Recorded;submit_report(cl,r,report_record,&recorded)
 answer_next(t,&f,"/reports",201,`{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","status":"pending"}`)
 answer_next(t,&f,"/reports/aaaaaaaaaaaaaaaaaaaaaaaa/upload",200,`{"url":"https://upload.example.com/","fields":{"key":"fixture"}}`)
 answer(&f,open_request(&f),0)
 testing.expect(t,!r.pending && !r.uploaded)
 testing.expect(t,submit_report(cl,r,report_record,&recorded))
 testing.expect_value(t,count_requests(&f,"/reports"),1)
 core_invalidate_session(&cl.core)
 answer_next(t,&f,"/reports/aaaaaaaaaaaaaaaaaaaaaaaa",200,`{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","status":"pending"}`)
 testing.expect(t,!r.pending && !submit_report(cl,r,report_record,&recorded))
}
@(test)
test_report_refuses_foreign_upload_and_control_injection :: proc(t:^testing.T) {
 for grant in ([]string{`{"url":"https://localhost/","fields":{"key":"x"}}`,`{"url":"https://upload.example.com@evil.test/","fields":{"key":"x"}}`,`{"url":"https://upload.example.com/","fields":{"file":"x"}}`,`{"url":"https://upload.example.com/","fields":{"key":"a\r\nheader"}}`}) {
  f:Fake;fake_init(&f)
  cl:=fake_client(t,&f,Config{disable_lifecycle_events=true});core_want_session(&cl.core);boot_client(t,&f,cl)
  r,_:=create_report(Report_Input{client_id="fixture-003",message="Bug",png=transmute([]u8)string(REPORT_TEST_PNG),consent=true})
  recorded:Report_Recorded;submit_report(cl,r,report_record,&recorded)
  answer_next(t,&f,"/reports",201,`{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","status":"pending"}`)
  answer_next(t,&f,"/reports/aaaaaaaaaaaaaaaaaaaaaaaa/upload",200,grant)
  testing.expect(t,recorded.reason=="invalid_upload" && !r.pending)
  testing.expect_value(t,open_request(&f),-1)
  destroy_report(r);close_client(cl);fake_destroy(&f)
 }
}
// The upload address check. No storage host is built in: the address must be
// https, a plain host name with no user info or port, and, for a report that
// already had an upload address, the same host the API returned for it before.
REPORT_UPLOAD_ADDRESSES :: [?]string{"https://upload.example.com/", "https://upload.example.com", "https://a.dotted.bucket.upload.example.com/", "https://files.example.org/player-reports/"}
@(test)
test_report_upload_accepts_the_api_https_address_end_to_end :: proc(t:^testing.T) {
 for grant_url in REPORT_UPLOAD_ADDRESSES {
  f:Fake;fake_init(&f)
  cl:=fake_client(t,&f,Config{disable_lifecycle_events=true});core_want_session(&cl.core);boot_client(t,&f,cl)
  r,_:=create_report(Report_Input{client_id="fixture-004",message="Bug",png=transmute([]u8)string(REPORT_TEST_PNG),consent=true})
  recorded:Report_Recorded;testing.expect(t,submit_report(cl,r,report_record,&recorded))
  answer_next(t,&f,"/reports",201,`{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","status":"pending"}`)
  answer_next(t,&f,"/reports/aaaaaaaaaaaaaaaaaaaaaaaa/upload",200,strings.concatenate({`{"url":"`,grant_url,`","fields":{"key":"fixture","Policy":"signed"}}`},context.temp_allocator))
  idx:=open_request(&f)
  testing.expectf(t,idx>=0,"no upload sent for %s",grant_url)
  if idx>=0 {
   upload:=f.requests[idx]
   testing.expect_value(t,upload.path,grant_url)
   testing.expect(t,strings.contains(upload.body,REPORT_TEST_PNG));testing.expect(t,strings.contains(upload.body,`name="key"`))
   testing.expect(t,!has_header(upload,"X-Session-Token: tok_1"));testing.expect(t,len(upload.headers)==1)
   answer(&f,idx,204)
   answer_next(t,&f,"/reports/aaaaaaaaaaaaaaaaaaaaaaaa/finalize",202,`{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","status":"processing"}`)
   testing.expectf(t,recorded.status=="processing","%s: %s",grant_url,recorded.reason)
  }
  destroy_report(r);close_client(cl);fake_destroy(&f)
 }
}
@(test)
test_report_upload_refuses_http_userinfo_port_and_local_addresses :: proc(t:^testing.T) {
 refused:=[?]string{
  "http://upload.example.com/",              // http
  "https://user:secret@upload.example.com/", // user info
  "https://user@upload.example.com/",        // user info, no password
  "https://upload.example.com:8443/",        // an explicit port
  "https://localhost/",                      // localhost
  "https://uploads.localhost/",              // a localhost name
  "https://127.0.0.1/",                      // an address literal
  "https://[::1]/",                          // an address literal
  "https:///",                               // no host
  "https://.example.com/",                   // a malformed host
  "https://upload..example.com/",            // a malformed host
  "https://upload.example.com /",            // a space
  "https://upload.example.com/a b",          // a space in the path
  "https://upload.example.com/?x=1#y",       // a query or fragment
  "ftp://upload.example.com/",               // not https
  "https:/upload.example.com/",              // not an address
 }
 for url in refused {
  f:Fake;fake_init(&f)
  cl:=fake_client(t,&f,Config{disable_lifecycle_events=true});core_want_session(&cl.core);boot_client(t,&f,cl)
  r,_:=create_report(Report_Input{client_id="fixture-005",message="Bug",png=transmute([]u8)string(REPORT_TEST_PNG),consent=true})
  recorded:Report_Recorded;submit_report(cl,r,report_record,&recorded)
  answer_next(t,&f,"/reports",201,`{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","status":"pending"}`)
  answer_next(t,&f,"/reports/aaaaaaaaaaaaaaaaaaaaaaaa/upload",200,strings.concatenate({`{"url":"`,url,`","fields":{"key":"x"}}`},context.temp_allocator))
  testing.expectf(t,recorded.reason=="invalid_upload" && !r.pending,"accepted %s",url)
  testing.expectf(t,open_request(&f)==-1,"sent an upload to %s",url)
  destroy_report(r);close_client(cl);fake_destroy(&f)
 }
}
@(test)
test_report_upload_retry_goes_only_to_the_host_the_api_returned :: proc(t:^testing.T) {
 f:Fake;fake_init(&f);defer fake_destroy(&f)
 cl:=fake_client(t,&f,Config{disable_lifecycle_events=true});defer close_client(cl);core_want_session(&cl.core);boot_client(t,&f,cl)
 r,_:=create_report(Report_Input{client_id="fixture-006",message="Bug",png=transmute([]u8)string(REPORT_TEST_PNG),consent=true});defer destroy_report(r)
 recorded:Report_Recorded;testing.expect(t,submit_report(cl,r,report_record,&recorded))
 answer_next(t,&f,"/reports",201,`{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","status":"pending"}`)
 answer_next(t,&f,"/reports/aaaaaaaaaaaaaaaaaaaaaaaa/upload",200,`{"url":"https://upload.example.com/","fields":{"key":"x"}}`)
 answer_next(t,&f,"https://upload.example.com/",0)
 testing.expect(t,!r.pending && !r.uploaded)
 // The retry's grant names another host: refused, nothing sent.
 testing.expect(t,submit_report(cl,r,report_record,&recorded))
 answer_next(t,&f,"/reports/aaaaaaaaaaaaaaaaaaaaaaaa",200,`{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","status":"pending"}`)
 answer_next(t,&f,"/reports/aaaaaaaaaaaaaaaaaaaaaaaa/upload",200,`{"url":"https://other.example.net/","fields":{"key":"x"}}`)
 testing.expect(t,recorded.reason=="invalid_upload" && !r.pending)
 testing.expect_value(t,open_request(&f),-1)
 // The same host again, in any case, is the API's own address for this report.
 testing.expect(t,submit_report(cl,r,report_record,&recorded))
 answer_next(t,&f,"/reports/aaaaaaaaaaaaaaaaaaaaaaaa",200,`{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","status":"pending"}`)
 answer_next(t,&f,"/reports/aaaaaaaaaaaaaaaaaaaaaaaa/upload",200,`{"url":"https://UPLOAD.example.com/","fields":{"key":"x"}}`)
 idx:=open_request(&f)
 testing.expect(t,idx>=0)
 if idx>=0 {
  testing.expect_value(t,f.requests[idx].path,"https://UPLOAD.example.com/")
  answer(&f,idx,204)
  answer_next(t,&f,"/reports/aaaaaaaaaaaaaaaaaaaaaaaa/finalize",202,`{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","status":"processing"}`)
  testing.expect(t,recorded.status=="processing" && !r.pending)
 }
}
