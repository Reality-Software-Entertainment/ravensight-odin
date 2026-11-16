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
 answer_next(t,&f,"/reports/aaaaaaaaaaaaaaaaaaaaaaaa/upload",200,`{"url":"https://fixture.s3.us-east-1.amazonaws.com/","fields":{"key":"fixture","Policy":"signed"}}`)
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
 answer_next(t,&f,"/reports/aaaaaaaaaaaaaaaaaaaaaaaa/upload",200,`{"url":"https://fixture.s3.amazonaws.com/","fields":{"key":"fixture"}}`)
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
 for grant in ([]string{`{"url":"https://localhost/","fields":{"key":"x"}}`,`{"url":"https://fixture.s3.amazonaws.com@evil.test/","fields":{"key":"x"}}`,`{"url":"https://fixture.s3.amazonaws.com/","fields":{"file":"x"}}`,`{"url":"https://fixture.s3.amazonaws.com/","fields":{"key":"a\r\nheader"}}`}) {
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
// The upload host pin. Accepted: the grant shapes the API's signer returns today
// (virtual-host bucket, regional or global endpoint, dotted bucket names).
REPORT_SIGNED_HOSTS :: [?]string{"ravensight-player-reports.s3.us-east-1.amazonaws.com", "fixture.s3.us-west-2.amazonaws.com", "a.dotted.bucket.s3.eu-west-1.amazonaws.com", "fixture.s3.amazonaws.com"}
@(test)
test_report_upload_pin_accepts_signed_hosts_end_to_end :: proc(t:^testing.T) {
 for host in REPORT_SIGNED_HOSTS {
  f:Fake;fake_init(&f)
  cl:=fake_client(t,&f,Config{disable_lifecycle_events=true});core_want_session(&cl.core);boot_client(t,&f,cl)
  r,_:=create_report(Report_Input{client_id="fixture-004",message="Bug",png=transmute([]u8)string(REPORT_TEST_PNG),consent=true})
  recorded:Report_Recorded;testing.expect(t,submit_report(cl,r,report_record,&recorded))
  answer_next(t,&f,"/reports",201,`{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","status":"pending"}`)
  grant_url:=strings.concatenate({"https://",host,"/"},context.temp_allocator)
  answer_next(t,&f,"/reports/aaaaaaaaaaaaaaaaaaaaaaaa/upload",200,strings.concatenate({`{"url":"`,grant_url,`","fields":{"key":"fixture","Policy":"signed"}}`},context.temp_allocator))
  idx:=open_request(&f)
  testing.expectf(t,idx>=0,"no upload sent for %s",host)
  if idx>=0 {
   upload:=f.requests[idx]
   testing.expect_value(t,upload.path,grant_url)
   testing.expect(t,strings.contains(upload.body,REPORT_TEST_PNG));testing.expect(t,strings.contains(upload.body,`name="key"`))
   testing.expect(t,!has_header(upload,"X-Session-Token: tok_1"));testing.expect(t,len(upload.headers)==1)
   answer(&f,idx,204)
   answer_next(t,&f,"/reports/aaaaaaaaaaaaaaaaaaaaaaaa/finalize",202,`{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","status":"processing"}`)
   testing.expectf(t,recorded.status=="processing","%s: %s",host,recorded.reason)
  }
  destroy_report(r);close_client(cl);fake_destroy(&f)
 }
}
@(test)
test_report_upload_pin_refuses_every_other_host :: proc(t:^testing.T) {
 refused:=[?]string{
  "https://foreign.example/",                                // a foreign https host
  "https://fixture.s3.us-east-1.amazonaws.com.evil.example/", // a look-alike suffix
  "http://fixture.s3.us-east-1.amazonaws.com/",               // http
  "https://localhost/",                                       // localhost
  "https://127.0.0.1/",                                       // an IP literal
  "https://user:secret@fixture.s3.us-east-1.amazonaws.com/",  // userinfo
  "https://fixture.s3.us-east-1.amazonaws.com:8443/",         // an explicit port
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
