#define LIGHTMESSAGING_USE_ROCKETBOOTSTRAP 0
#import "LightMessaging/LightMessaging.h"

#import "rocketbootstrap_internal.h"

#ifndef __APPLE_API_PRIVATE
#define __APPLE_API_PRIVATE
#include "sandbox.h"
#undef __APPLE_API_PRIVATE
#else
#include "sandbox.h"
#endif

#import <mach/mach.h>
#import <substrate.h>
#import <libkern/OSAtomic.h>
//#import <launch.h>
#import <CoreFoundation/CFUserNotification.h>

extern int *_NSGetArgc(void);
extern const char ***_NSGetArgv(void);

#define kUserAppsPath "/var/mobile/Applications/"
#define kSystemAppsPath "/Applications/"

static BOOL isDaemon;

kern_return_t rocketbootstrap_look_up(mach_port_t bp, const name_t service_name, mach_port_t *sp)
{
	if (rocketbootstrap_is_passthrough() || isDaemon) {
		if (kCFCoreFoundationVersionNumber >= kCFCoreFoundationVersionNumber_iOS_5_0) {
			int sandbox_result = sandbox_check(getpid(), "mach-lookup", SANDBOX_FILTER_LOCAL_NAME | SANDBOX_CHECK_NO_REPORT, service_name);
			if (sandbox_result) {
				return sandbox_result;
			}
		}
		return bootstrap_look_up(bp, service_name, sp);
	}
	// Compatibility mode for Flex, limits it to only the processes in rbs 1.0.1 and earlier
	if (strcmp(service_name, "FLMessagingCenterSpringboard") == 0) {
		const char **argv = *_NSGetArgv();
		size_t arg0len = strlen(argv[0]);
		bool allowed = false;
		if ((arg0len > sizeof(kUserAppsPath)) && (memcmp(argv[0], kUserAppsPath, sizeof(kUserAppsPath) - 1) == 0))
			allowed = true;
		if ((arg0len > sizeof(kSystemAppsPath)) && (memcmp(argv[0], kSystemAppsPath, sizeof(kSystemAppsPath) - 1) == 0))
			allowed = true;
		if (!allowed)
			return 1;
	}
	// Ask our service running inside of the com.apple.ReportCrash.SimulateCrash job
	mach_port_t servicesPort = MACH_PORT_NULL;
	kern_return_t err = bootstrap_look_up(bp, "com.apple.ReportCrash.SimulateCrash", &servicesPort);
	if (err)
		return err;
	mach_port_t selfTask = mach_task_self();
	// Create a reply port
	mach_port_name_t replyPort = MACH_PORT_NULL;
	err = mach_port_allocate(selfTask, MACH_PORT_RIGHT_RECEIVE, &replyPort);
	if (err) {
		mach_port_deallocate(selfTask, servicesPort);
		return err;
	}
	// Send message
	size_t service_name_size = strlen(service_name);
	size_t size = (sizeof(_rocketbootstrap_lookup_query_t) + service_name_size + 3) & ~3;
	if (size < sizeof(_rocketbootstrap_lookup_response_t)) {
		size = sizeof(_rocketbootstrap_lookup_response_t);
	}
	char buffer[size];
	_rocketbootstrap_lookup_query_t *message = (_rocketbootstrap_lookup_query_t *)&buffer[0];
	memset(message, 0, sizeof(_rocketbootstrap_lookup_response_t));
	message->head.msgh_id = ROCKETBOOTSTRAP_LOOKUP_ID;
	message->head.msgh_size = size;
	message->head.msgh_remote_port = servicesPort;
	message->head.msgh_local_port = replyPort;
	message->head.msgh_reserved = 0;
	message->head.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
	message->name_length = service_name_size;
	memcpy(&message->name[0], service_name, service_name_size);
	err = mach_msg(&message->head, MACH_SEND_MSG | MACH_RCV_MSG, size, size, replyPort, 0, MACH_PORT_NULL);
	// Parse response
	if (!err) {
		_rocketbootstrap_lookup_response_t *response = (_rocketbootstrap_lookup_response_t *)message;
		if (response->body.msgh_descriptor_count)
			*sp = response->response_port.name;
		else
			err = 1;
	}
	// Cleanup
	mach_port_deallocate(selfTask, servicesPort);
	mach_port_deallocate(selfTask, replyPort);
	return err;
}

static NSMutableSet *allowedNames;
static volatile OSSpinLock namesLock;

static void daemon_restarted_callback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo)
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	OSSpinLockLock(&namesLock);
	NSSet *allNames = [allowedNames copy];
	OSSpinLockUnlock(&namesLock);
	for (NSString *name in allNames) {
		const char *service_name = [name UTF8String];
		LMConnectionSendOneWay(&connection, 0, service_name, strlen(service_name));             
	}
	[allNames release];
	[pool drain];
}

kern_return_t rocketbootstrap_unlock(const name_t service_name)
{
	if (rocketbootstrap_is_passthrough())
		return 0;
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSString *serviceNameString = [NSString stringWithUTF8String:service_name];
	OSSpinLockLock(&namesLock);
	BOOL containedName = [allowedNames containsObject:serviceNameString];
	OSSpinLockUnlock(&namesLock);
	if (containedName) {
		[pool drain];
		return 0;
	}
	// Ask rocketd to unlock it for us
	int sandbox_result = sandbox_check(getpid(), "mach-lookup", SANDBOX_FILTER_LOCAL_NAME | SANDBOX_CHECK_NO_REPORT, kRocketBootstrapUnlockService);
	if (sandbox_result) {
		[pool drain];
		return sandbox_result;
	}
	kern_return_t result = LMConnectionSendOneWay(&connection, 0, service_name, strlen(service_name));
	if (!result) {
		OSSpinLockLock(&namesLock);
		if (!allowedNames) {
			allowedNames = [[NSMutableSet alloc] init];
			CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), &daemon_restarted_callback, daemon_restarted_callback, CFSTR("com.rpetrich.rocketd.started"), NULL, CFNotificationSuspensionBehaviorCoalesce);
		}
		[allowedNames addObject:serviceNameString];
		OSSpinLockUnlock(&namesLock);
	}
	[pool drain];
	return result;
}

#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
kern_return_t rocketbootstrap_register(mach_port_t bp, name_t service_name, mach_port_t sp)
{
	kern_return_t err = rocketbootstrap_unlock(service_name);
	if (err)
		return err;
	return bootstrap_register(bp, service_name, sp);
}
#pragma GCC diagnostic warning "-Wdeprecated-declarations"

mach_msg_return_t mach_msg_server_once(boolean_t (*demux)(mach_msg_header_t *, mach_msg_header_t *), mach_msg_size_t max_size, mach_port_t rcv_name, mach_msg_options_t options);

mach_msg_return_t (*_mach_msg_server_once)(boolean_t (*demux)(mach_msg_header_t *, mach_msg_header_t *), mach_msg_size_t max_size, mach_port_t rcv_name, mach_msg_options_t options);

static volatile OSSpinLock server_once_lock;
static boolean_t (*server_once_demux_orig)(mach_msg_header_t *, mach_msg_header_t *);
static bool continue_server_once;

static boolean_t new_demux(mach_msg_header_t *request, mach_msg_header_t *reply)
{
	// Highjack ROCKETBOOTSTRAP_LOOKUP_ID from the com.apple.ReportCrash.SimulateCrash demuxer
	if (request->msgh_id == ROCKETBOOTSTRAP_LOOKUP_ID) {
		continue_server_once = true;
		_rocketbootstrap_lookup_query_t *lookup_message = (_rocketbootstrap_lookup_query_t *)request;
		// Extract service name
		size_t length = request->msgh_size - offsetof(_rocketbootstrap_lookup_query_t, name);
		if (lookup_message->name_length <= length) {
			length = lookup_message->name_length;
		}
		// Ask rocketd if it's unlocked
		LMResponseBuffer buffer;
		if (LMConnectionSendTwoWay(&connection, 1, &lookup_message->name[0], length, &buffer))
			return false;
		if (!LMResponseConsumeInteger(&buffer))
			return false;
		// Lookup service port
		mach_port_t servicePort = MACH_PORT_NULL;
		mach_port_t selfTask = mach_task_self();
		BOOL nameIsAllowed = YES;
		kern_return_t err;
		if (nameIsAllowed) {
			mach_port_t bootstrap = MACH_PORT_NULL;
			err = task_get_bootstrap_port(selfTask, &bootstrap);
			if (!err) {
				NSString *name = [[NSString alloc] initWithBytes:&lookup_message->name[0] length:length encoding:NSUTF8StringEncoding];
				bootstrap_look_up(bootstrap, [name UTF8String], &servicePort);
				[name release];
			}
		}
		// Generate response
		_rocketbootstrap_lookup_response_t response;
		response.head.msgh_id = 0;
		response.head.msgh_size = (sizeof(_rocketbootstrap_lookup_response_t) + 3) & ~3;
		response.head.msgh_remote_port = request->msgh_remote_port;
		response.head.msgh_local_port = MACH_PORT_NULL;
		response.head.msgh_reserved = 0;
		response.head.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
		if (servicePort != MACH_PORT_NULL) {
			response.head.msgh_bits |= MACH_MSGH_BITS_COMPLEX;
			response.body.msgh_descriptor_count = 1;
			response.response_port.name = servicePort;
			response.response_port.disposition = MACH_MSG_TYPE_COPY_SEND;
			response.response_port.type = MACH_MSG_PORT_DESCRIPTOR;
		} else {
			response.body.msgh_descriptor_count = 0;
		}
		// Send response
		err = mach_msg(&response.head, MACH_SEND_MSG, response.head.msgh_size, 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
		if (err) {
			if (servicePort != MACH_PORT_NULL)
				mach_port_mod_refs(selfTask, servicePort, MACH_PORT_RIGHT_SEND, -1);
			mach_port_mod_refs(selfTask, reply->msgh_remote_port, MACH_PORT_RIGHT_SEND_ONCE, -1);
		}
		return true;
	}
	return server_once_demux_orig(request, reply);
}

static mach_msg_return_t $mach_msg_server_once(boolean_t (*demux)(mach_msg_header_t *, mach_msg_header_t *), mach_msg_size_t max_size, mach_port_t rcv_name, mach_msg_options_t options)
{
	// Highjack com.apple.ReportCrash.SimulateCrash's use of mach_msg_server_once
	OSSpinLockLock(&server_once_lock);
	if (!server_once_demux_orig) {
		server_once_demux_orig = demux;
		demux = new_demux;
	} else if (server_once_demux_orig == demux) {
		demux = new_demux;
	} else {
		OSSpinLockUnlock(&server_once_lock);
		mach_msg_return_t result = _mach_msg_server_once(demux, max_size, rcv_name, options);
		return result;
	}
	OSSpinLockUnlock(&server_once_lock);
	mach_msg_return_t result;
	do {
		continue_server_once = false;
		result = _mach_msg_server_once(demux, max_size, rcv_name, options);
	} while (continue_server_once);
	return result;
}

static void SanityCheckNotificationCallback(CFUserNotificationRef userNotification, CFOptionFlags responseFlags)
{
}

%ctor
{
	%init();
	// Attach rockets when in the com.apple.ReportCrash.SimulateCrash job
	// (can't check in using the launchd APIs because it hates more than one checkin; this will do)
	const char **argv = *_NSGetArgv();
	if (strcmp(argv[0], "/System/Library/CoreServices/ReportCrash") == 0 && argv[1] && strcmp(argv[1], "-f") == 0) {
		isDaemon = YES;
		MSHookFunction(mach_msg_server_once, $mach_msg_server_once, (void **)&_mach_msg_server_once);
	} else if (strcmp(argv[0], "/System/Library/CoreServices/SpringBoard.app/SpringBoard") == 0) {
		// Sanity check on the SimulateCrash service
		mach_port_t bootstrap = MACH_PORT_NULL;
		task_get_bootstrap_port(mach_task_self(), &bootstrap);
		mach_port_t servicesPort = MACH_PORT_NULL;
		kern_return_t err = bootstrap_look_up(bootstrap, "com.apple.ReportCrash.SimulateCrash", &servicesPort);
		if (err) {
			const CFTypeRef keys[] = {
				kCFUserNotificationAlertHeaderKey,
				kCFUserNotificationAlertMessageKey,
				kCFUserNotificationDefaultButtonTitleKey,
			};
			const CFTypeRef values[] = {
				CFSTR("System files missing!"),
				CFSTR("RocketBootstrap has detected that your SimulateCrash crash reporting daemon is missing or disabled.\nThis daemon is required for proper operation of packages that depend on RocketBootstrap."),
				CFSTR("OK"),
			};
			CFDictionaryRef dict = CFDictionaryCreate(kCFAllocatorDefault, (const void **)keys, (const void **)values, sizeof(keys) / sizeof(*keys), &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
			SInt32 err = 0;
			CFUserNotificationRef notification = CFUserNotificationCreate(kCFAllocatorDefault, 0.0, kCFUserNotificationPlainAlertLevel, &err, dict);
			CFRunLoopSourceRef runLoopSource = CFUserNotificationCreateRunLoopSource(kCFAllocatorDefault, notification, SanityCheckNotificationCallback, 0);
			CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, kCFRunLoopCommonModes);
			CFRelease(dict);
		}
	}
}
