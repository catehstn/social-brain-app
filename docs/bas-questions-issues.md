Questions
- It is mentioned the LinkedIn output can be a csv file, but I've only seen it
be an `.xlsx`. Is it valid that it can be both?
- MastodonOAuth's `authorise` function uses DispatchQueue; why? Is
`ASWebAuthenticationSession` not (yet) properly annotated for Swift Concurrency?
- What would it take to build out a 'demo mode' for users to get a better idea
of how the app works? It would use mock data and set up various platforms.
- When importing LinkedIn output, the app feedback is very minimal. I've only
seen a minor thing along the lines of "check, imported", but would there be
space to share more about what was imported to the user, to clarify and give
the user peace of mind that the data was imported successfully?

Issues
- Importing a LinkedIn `.xlsx` failed, particularly on code "skipping string
values" (line 96 in the LinkedInXLSXParser). Why is this check there in the
first place? In line 98, it still gets a `.stringValue` and line 99 would
discard values that can't be converted to a `Double` value anyway.
- Attempting to authorise Mastodon, things worked ok at the start, opening up a
proper `ASWebAuthenticationSession`, but then eventually it caused a crash.
This happens after "authorise"-ing in the web session on Mastodon. Its error
was `callbackURL=error: summary string parsing error`. On re-launch, Mastodon
has not been configured.
Backtrace:
```
* thread #46, queue = 'com.apple.NSXPCConnection.m-user.com.apple.SafariLaunchAgent', stop reason = EXC_BREAKPOINT (code=1, subcode=0x10371d774)
  * frame #0: 0x000000010371d774 libdispatch.dylib`_dispatch_assert_queue_fail + 120
    frame #1: 0x000000010371f010 libdispatch.dylib`dispatch_assert_queue$V2.cold.1 + 116
    frame #2: 0x00000001036e3758 libdispatch.dylib`dispatch_assert_queue + 108
    frame #3: 0x000000028a11d57c libswift_Concurrency.dylib`_swift_task_checkIsolatedSwift + 48
    frame #4: 0x000000028a0cd11c libswift_Concurrency.dylib`swift_task_isCurrentExecutorWithFlagsImpl(swift::SerialExecutorRef, swift::swift_task_is_current_executor_flag) + 356
    frame #5: 0x00000001043e7134 SocialBrain.debug.dylib`closure #1 in closure #1 in closure #1 in static MastodonOAuth.authorise(callbackURL=error: summary string parsing error, error=nil, continuation=Swift.CheckedContinuation<Swift.String, Swift.Error> @ 0x0000000a309b9ed0) at <stdin>:0
    frame #7: 0x00000001bce1bf18 AuthenticationServices`__102-[ASWebAuthenticationSession initWithURL:callback:usingEphemeralSession:jitEnabled:completionHandler:]_block_invoke + 300
    frame #8: 0x00000001bce1c8c4 AuthenticationServices`-[ASWebAuthenticationSession _endSessionWithCallbackURL:error:] + 48
    frame #9: 0x00000001bce1c4b4 AuthenticationServices`__43-[ASWebAuthenticationSession _startDryRun:]_block_invoke_2 + 216
    frame #10: 0x000000018575f634 CoreFoundation`__invoking___ + 148
    frame #11: 0x000000018575f4c0 CoreFoundation`-[NSInvocation invoke] + 424
    frame #12: 0x0000000186f8d5c8 Foundation`__NSXPCCONNECTION_IS_CALLING_OUT_TO_REPLY_BLOCK__ + 16
    frame #13: 0x0000000186f8bd64 Foundation`-[NSXPCConnection _decodeAndInvokeReplyBlockWithEvent:sequence:replyInfo:] + 528
    frame #14: 0x0000000186f8b6c0 Foundation`__88-[NSXPCConnection _sendInvocation:orArguments:count:methodSignature:selector:withProxy:]_block_invoke_3 + 188
    frame #15: 0x000000018539ec00 libxpc.dylib`_xpc_connection_reply_callout + 120
    frame #16: 0x000000018539eaf8 libxpc.dylib`_xpc_connection_call_reply_async + 96
    frame #17: 0x00000001036fcf10 libdispatch.dylib`_dispatch_client_callout3_a + 16
    frame #18: 0x0000000103701f84 libdispatch.dylib`_dispatch_mach_msg_async_reply_invoke + 396
    frame #19: 0x00000001036e9150 libdispatch.dylib`_dispatch_lane_serial_drain + 344
    frame #20: 0x00000001036ea218 libdispatch.dylib`_dispatch_lane_invoke + 488
    frame #21: 0x00000001036f7b84 libdispatch.dylib`_dispatch_root_queue_drain_deferred_wlh + 664
    frame #22: 0x00000001036f7064 libdispatch.dylib`_dispatch_workloop_worker_thread + 780
    frame #23: 0x0000000102c8f7f4 libsystem_pthread.dylib`_pthread_wqthread + 292
```
