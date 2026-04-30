#import "XLMetricKit.h"

#import <Foundation/Foundation.h>

#if __has_include(<MetricKit/MetricKit.h>)
#import <MetricKit/MetricKit.h>

API_AVAILABLE(macos(12.0), ios(13.0))
@interface XLMetricKitSubscriber : NSObject <MXMetricManagerSubscriber>
@property (nonatomic, copy) NSString* diagnosticsDir;
@end

@implementation XLMetricKitSubscriber

- (void)writeJSON:(NSData*)json kind:(NSString*)kind index:(NSUInteger)idx {
    if (!self.diagnosticsDir || json.length == 0) return;

    NSFileManager* fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:self.diagnosticsDir
  withIntermediateDirectories:YES
                   attributes:nil
                        error:nil];

    NSDateFormatter* fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyyMMdd-HHmmss";
    fmt.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    NSString* stamp = [fmt stringFromDate:[NSDate date]];

    NSString* filename = [NSString stringWithFormat:@"%@-%@-%lu.json",
                          stamp, kind, (unsigned long)idx];
    NSString* path = [self.diagnosticsDir stringByAppendingPathComponent:filename];
    [json writeToFile:path atomically:YES];

    // iPad observers (the diagnostic uploader) listen for this and
    // bundle the JSON into a PendingUpload/ zip. On macOS nothing
    // listens — the wx debug-report path picks up the JSON files
    // directly out of Diagnostics/ next time it builds a zip.
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"XLMetricKitDidReceivePayloads" object:nil];
}

- (void)didReceiveMetricPayloads:(NSArray<MXMetricPayload*>*)payloads {
    NSUInteger idx = 0;
    for (MXMetricPayload* payload in payloads) {
        [self writeJSON:[payload JSONRepresentation] kind:@"metrics" index:idx++];
    }
}

- (void)didReceiveDiagnosticPayloads:(NSArray<MXDiagnosticPayload*>*)payloads
    API_AVAILABLE(macos(12.0), ios(14.0)) {
    NSUInteger idx = 0;
    for (MXDiagnosticPayload* payload in payloads) {
        [self writeJSON:[payload JSONRepresentation] kind:@"diagnostics" index:idx++];
    }
}

@end

// `id` (rather than `XLMetricKitSubscriber*`) so the file-scope
// declaration doesn't trip the macOS-12-availability check on
// macOS 11 deployment targets. The actual instantiation is gated
// behind @available below.
static id sSubscriber = nil;
#endif // __has_include(<MetricKit/MetricKit.h>)

void StartMetricKitCollection(const std::string& diagnosticsDir) {
#if __has_include(<MetricKit/MetricKit.h>)
    if (@available(macOS 12.0, iOS 13.0, *)) {
        if (sSubscriber) return;
        NSString* dir = [NSString stringWithUTF8String:diagnosticsDir.c_str()];
        if (dir.length == 0) return;

        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];

        XLMetricKitSubscriber* sub = [[XLMetricKitSubscriber alloc] init];
        sub.diagnosticsDir = dir;
        [[MXMetricManager sharedManager] addSubscriber:sub];
        sSubscriber = sub;
    }
#endif
}
