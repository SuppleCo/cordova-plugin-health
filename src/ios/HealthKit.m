#import "HealthKit.h"
#import "HKHealthStore+AAPLExtensions.h"
#import "WorkoutActivityConversion.h"
#import <CoreLocation/CoreLocation.h>

#pragma clang diagnostic push
#pragma ide diagnostic ignored "OCNotLocalizedStringInspection"
#define HKPLUGIN_DEBUG

#pragma mark Property Type Constants
static NSString *const HKPluginError = @"HKPluginError";
static NSString *const HKPluginKeyReadTypes = @"readTypes";
static NSString *const HKPluginKeyWriteTypes = @"writeTypes";
static NSString *const HKPluginKeyType = @"type";
static NSString *const HKPluginKeyStartDate = @"startDate";
static NSString *const HKPluginKeyEndDate = @"endDate";
static NSString *const HKPluginKeySampleType = @"sampleType";
static NSString *const HKPluginKeyAggregation = @"aggregation";
static NSString *const HKPluginKeyUnit = @"unit";
static NSString *const HKPluginKeyUnits = @"units";
static NSString *const HKPluginKeyAmount = @"amount";
static NSString *const HKPluginKeyValue = @"value";
static NSString *const HKPluginKeyCorrelationType = @"correlationType";
static NSString *const HKPluginKeyObjects = @"samples";
static NSString *const HKPluginKeySourceName = @"sourceName";
static NSString *const HKPluginKeySourceBundleId = @"sourceBundleId";
static NSString *const HKPluginKeyMetadata = @"metadata";
static NSString *const HKPluginKeyUUID = @"UUID";

#pragma mark Categories

// NSDictionary check if there is a value for a required key and populate an error if not present
@interface NSDictionary (RequiredKey)
- (BOOL)hasAllRequiredKeys:(NSArray<NSString *> *)keys error:(NSError **)error;
@end

// Public Interface extension category
@interface HealthKit ()
+ (HKHealthStore *)sharedHealthStore;
@end

// Internal interface
@interface HealthKit (Internal)
- (void)checkAuthStatusWithCallbackId:(NSString *)callbackId
                              forType:(HKObjectType *)type
                        andCompletion:(void (^)(CDVPluginResult *result, NSString *innerCallbackId))completion;
@end


// Internal interface helper methods
@interface HealthKit (InternalHelpers)
+ (NSString *)stringFromDate:(NSDate *)date;

+ (HKUnit *)getUnit:(NSString *)type expected:(NSString *)expected;

+ (HKObjectType *)getHKObjectType:(NSString *)elem;

+ (HKQuantityType *)getHKQuantityType:(NSString *)elem;

+ (HKSampleType *)getHKSampleType:(NSString *)elem;

- (HKQuantitySample *)loadHKSampleFromInputDictionary:(NSDictionary *)inputDictionary error:(NSError **)error;

- (HKCorrelation *)loadHKCorrelationFromInputDictionary:(NSDictionary *)inputDictionary error:(NSError **)error;

+ (HKQuantitySample *)getHKQuantitySampleWithStartDate:(NSDate *)startDate endDate:(NSDate *)endDate sampleTypeString:(NSString *)sampleTypeString unitTypeString:(NSString *)unitTypeString value:(double)value metadata:(NSDictionary *)metadata error:(NSError **)error;

- (HKCorrelation *)getHKCorrelationWithStartDate:(NSDate *)startDate endDate:(NSDate *)endDate correlationTypeString:(NSString *)correlationTypeString objects:(NSSet *)objects metadata:(NSDictionary *)metadata error:(NSError **)error;

+ (void)triggerErrorCallbackWithMessage: (NSString *) message command: (CDVInvokedUrlCommand *) command delegate: (id<CDVCommandDelegate>) delegate;
@end

/**
 * Implementation of internal interface
 * **************************************************************************************
 */
#pragma mark Internal Interface

@implementation HealthKit (Internal)

/**
 * Check the authorization status for a HealthKit type and dispatch the callback with result
 *
 * @param callbackId    *NSString
 * @param type          *HKObjectType
 * @param completion    void(^)
 */
- (void)checkAuthStatusWithCallbackId:(NSString *)callbackId forType:(HKObjectType *)type andCompletion:(void (^)(CDVPluginResult *, NSString *))completion {

    CDVPluginResult *pluginResult = nil;

    if (type == nil) {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"type is an invalid value"];
    } else {
        HKAuthorizationStatus status = [[HealthKit sharedHealthStore] authorizationStatusForType:type];

        NSString *authorizationResult = nil;
        switch (status) {
            case HKAuthorizationStatusSharingAuthorized:
                authorizationResult = @"authorized";
                break;
            case HKAuthorizationStatusSharingDenied:
                authorizationResult = @"denied";
                break;
            default:
                authorizationResult = @"undetermined";
        }

#ifdef HKPLUGIN_DEBUG
        NSLog(@"Health store returned authorization status: %@ for type %@", authorizationResult, [type description]);
#endif

        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:authorizationResult];
    }

    completion(pluginResult, callbackId);
}

@end

/**
 * Implementation of internal helpers interface
 * **************************************************************************************
 */
#pragma mark Internal Helpers

@implementation HealthKit (InternalHelpers)

/**
 * Get a string representation of an NSDate object
 *
 * @param date  *NSDate
 * @return      *NSString
 */
+ (NSString *)stringFromDate:(NSDate *)date {
    __strong static NSISO8601DateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSISO8601DateFormatter alloc] init];
        formatter.formatOptions = NSISO8601DateFormatWithFractionalSeconds | NSISO8601DateFormatWithInternetDateTime;
    });

    return [formatter stringFromDate:date];
}

/**
 * Get a HealthKit unit and make sure its local representation matches what is expected
 *
 * @param type      *NSString
 * @param expected  *NSString
 * @return          *HKUnit
 */
+ (HKUnit *)getUnit:(NSString *)type expected:(NSString *)expected {
    HKUnit *localUnit;
    @try {
        // this throws an exception instead of returning nil if type is unknown
        localUnit = [HKUnit unitFromString:type];
        if ([[[localUnit class] description] isEqualToString:expected]) {
            return localUnit;
        } else {
            return nil;
        }
    }
    @catch (NSException *e) {
        return nil;
    }
}

/**
 * Get a HealthKit object type by name
 *
 * @param elem  *NSString
 * @return      *HKObjectType
 */
+ (HKObjectType *)getHKObjectType:(NSString *)elem {

    HKObjectType *type = nil;

    type = [HKObjectType quantityTypeForIdentifier:elem];
    if (type != nil) {
        return type;
    }

    type = [HKObjectType characteristicTypeForIdentifier:elem];
    if (type != nil) {
        return type;
    }

    // @TODO | The fall through here is inefficient.
    // @TODO | It needs to be refactored so the same HK method isnt called twice
    return [HealthKit getHKSampleType:elem];
}

/**
 * Get a HealthKit quantity type by name
 *
 * @param elem  *NSString
 * @return      *HKQuantityType
 */
+ (HKQuantityType *)getHKQuantityType:(NSString *)elem {
    return [HKQuantityType quantityTypeForIdentifier:elem];
}

/**
 * Get sample type by name
 *
 * @param elem  *NSString
 * @return      *HKSampleType
 */
+ (HKSampleType *)getHKSampleType:(NSString *)elem {

    HKSampleType *type = nil;

    type = [HKObjectType quantityTypeForIdentifier:elem];
    if (type != nil) {
        return type;
    }

    type = [HKObjectType categoryTypeForIdentifier:elem];
    if (type != nil) {
        return type;
    }

    type = [HKObjectType correlationTypeForIdentifier:elem];
    if (type != nil) {
        return type;
    }

    if ([elem isEqualToString:@"workoutType"]) {
        return [HKObjectType workoutType];
    }

    // leave this here for if/when apple adds other sample types
    return type;

}

/**
 * Parse out a sample from a dictionary and perform error checking
 *
 * @param inputDictionary   *NSDictionary
 * @param error             **NSError
 * @return                  *HKQuantitySample
 */
- (HKSample *)loadHKSampleFromInputDictionary:(NSDictionary *)inputDictionary error:(NSError **)error {
    //Load quantity sample from args to command

    if (![inputDictionary hasAllRequiredKeys:@[HKPluginKeyStartDate, HKPluginKeyEndDate, HKPluginKeySampleType] error:error]) {
        return nil;
    }

    NSDate *startDate = [NSDate dateWithTimeIntervalSince1970:[inputDictionary[HKPluginKeyStartDate] longValue]];
    NSDate *endDate = [NSDate dateWithTimeIntervalSince1970:[inputDictionary[HKPluginKeyEndDate] longValue]];
    NSString *sampleTypeString = inputDictionary[HKPluginKeySampleType];

    //Load optional metadata key
    NSDictionary *metadata = inputDictionary[HKPluginKeyMetadata];
    if (metadata == nil) {
      metadata = @{};
    }

    if ([inputDictionary objectForKey:HKPluginKeyUnit]) {
        if (![inputDictionary hasAllRequiredKeys:@[HKPluginKeyUnit] error:error]) return nil;
        NSString *unitString = [inputDictionary objectForKey:HKPluginKeyUnit];

            return [HealthKit getHKQuantitySampleWithStartDate:startDate
                                                   endDate:endDate
                                          sampleTypeString:sampleTypeString
                                            unitTypeString:unitString
                                                     value:[inputDictionary[HKPluginKeyAmount] doubleValue]
                                                  metadata:metadata error:error];
    } else {
            if (![inputDictionary hasAllRequiredKeys:@[HKPluginKeyValue] error:error]) return nil;
            NSString *categoryString = [inputDictionary objectForKey:HKPluginKeyValue];

            return [self getHKCategorySampleWithStartDate:startDate
                                                       endDate:endDate
                                              sampleTypeString:sampleTypeString
                                                categoryString:categoryString
                                                      metadata:metadata
                                                         error:error];
        }
  }

/**
 * Parse out a correlation from a dictionary and perform error checking
 *
 * @param inputDictionary   *NSDictionary
 * @param error             **NSError
 * @return                  *HKCorrelation
 */
- (HKCorrelation *)loadHKCorrelationFromInputDictionary:(NSDictionary *)inputDictionary error:(NSError **)error {
    //Load correlation from args to command

    if (![inputDictionary hasAllRequiredKeys:@[HKPluginKeyStartDate, HKPluginKeyEndDate, HKPluginKeyCorrelationType, HKPluginKeyObjects] error:error]) {
        return nil;
    }

    NSDate *startDate = [NSDate dateWithTimeIntervalSince1970:[inputDictionary[HKPluginKeyStartDate] longValue]];
    NSDate *endDate = [NSDate dateWithTimeIntervalSince1970:[inputDictionary[HKPluginKeyEndDate] longValue]];
    NSString *correlationTypeString = inputDictionary[HKPluginKeyCorrelationType];
    NSArray *objectDictionaries = inputDictionary[HKPluginKeyObjects];

    NSMutableSet *objects = [NSMutableSet set];
    for (NSDictionary *objectDictionary in objectDictionaries) {
        HKSample *sample = [self loadHKSampleFromInputDictionary:objectDictionary error:error];
        if (sample == nil) {
            return nil;
        }
        [objects addObject:sample];
    }

    NSDictionary *metadata = inputDictionary[HKPluginKeyMetadata];
    if (metadata == nil) {
        metadata = @{};
    }
    return [self getHKCorrelationWithStartDate:startDate
                                       endDate:endDate
                         correlationTypeString:correlationTypeString
                                       objects:objects
                                      metadata:metadata
                                         error:error];
}

/**
 * Query HealthKit to get a quantity sample in a specified date range
 *
 * @param startDate         *NSDate
 * @param endDate           *NSDate
 * @param sampleTypeString  *NSString
 * @param unitTypeString    *NSString
 * @param value             double
 * @param metadata          *NSDictionary
 * @param error             **NSError
 * @return                  *HKQuantitySample
 */
+ (HKQuantitySample *)getHKQuantitySampleWithStartDate:(NSDate *)startDate
                                               endDate:(NSDate *)endDate
                                      sampleTypeString:(NSString *)sampleTypeString
                                        unitTypeString:(NSString *)unitTypeString
                                                 value:(double)value
                                              metadata:(NSDictionary *)metadata
                                                 error:(NSError **)error {
    HKQuantityType *type = [HealthKit getHKQuantityType:sampleTypeString];
    if (type == nil) {
        if (error != nil) {
            *error = [NSError errorWithDomain:HKPluginError code:0 userInfo:@{NSLocalizedDescriptionKey: @"quantity type string was invalid"}];
        }

        return nil;
    }

    HKUnit *unit = nil;
    @try {
        if (unitTypeString != nil) {
            if ([unitTypeString isEqualToString:@"mmol/L"]) {
                // @see https://stackoverflow.com/a/30196642/1214598
                unit = [[HKUnit moleUnitWithMetricPrefix:HKMetricPrefixMilli molarMass:HKUnitMolarMassBloodGlucose] unitDividedByUnit:[HKUnit literUnit]];
            } else {
                // issue 51
                // @see https://github.com/Telerik-Verified-Plugins/HealthKit/issues/51
                if ([unitTypeString isEqualToString:@"percent"]) {
                    unitTypeString = @"%";
                }
                unit = [HKUnit unitFromString:unitTypeString];
            }
        } else {
            if (error != nil) {
                *error = [NSError errorWithDomain:HKPluginError code:0 userInfo:@{NSLocalizedDescriptionKey: @"unit is invalid"}];
            }
            return nil;
        }
    } @catch (NSException *e) {
        if (error != nil) {
            *error = [NSError errorWithDomain:HKPluginError code:0 userInfo:@{NSLocalizedDescriptionKey: @"unit is invalid"}];
        }
        return nil;
    }

    HKQuantity *quantity = [HKQuantity quantityWithUnit:unit doubleValue:value];
    if (![quantity isCompatibleWithUnit:unit]) {
        if (error != nil) {
            *error = [NSError errorWithDomain:HKPluginError code:0 userInfo:@{NSLocalizedDescriptionKey: @"unit is not compatible with quantity"}];
        }

        return nil;
    }

    return [HKQuantitySample quantitySampleWithType:type quantity:quantity startDate:startDate endDate:endDate metadata:metadata];
}

// Helper to handle the functionality with HealthKit to get a category sample
- (HKCategorySample*) getHKCategorySampleWithStartDate:(NSDate*) startDate endDate:(NSDate*) endDate sampleTypeString:(NSString*) sampleTypeString categoryString:(NSString*) categoryString metadata:(NSDictionary*) metadata error:(NSError**) error {
    HKCategoryType *type = [HKCategoryType categoryTypeForIdentifier:sampleTypeString];
    if (type==nil) {
      *error = [NSError errorWithDomain:HKPluginError code:0 userInfo:@{NSLocalizedDescriptionKey:@"quantity type string is invalid"}];
      return nil;
    }
    NSNumber* value = [self getCategoryValueByName:categoryString type:type];
    if (value == nil && ![type.identifier isEqualToString:@"HKCategoryTypeIdentifierMindfulSession"]) {
        *error = [NSError errorWithDomain:HKPluginError code:0 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"%@,%@,%@",@"category value is not compatible with category",type.identifier,categoryString]}];
        return nil;
    }

    return [HKCategorySample categorySampleWithType:type value:[value integerValue] startDate:startDate endDate:endDate];
}

- (NSNumber*) getCategoryValueByName:(NSString *) categoryValue type:(HKCategoryType*) type {
    NSDictionary * map;
    if (@available(iOS 16.0, *)) {
        map = @{
            @"HKCategoryTypeIdentifierSleepAnalysis":@{
                @"HKCategoryValueSleepAnalysisInBed":@(HKCategoryValueSleepAnalysisInBed),
                @"HKCategoryValueSleepAnalysisAsleep":@(HKCategoryValueSleepAnalysisAsleep),
                @"HKCategoryValueSleepAnalysisAwake":@(HKCategoryValueSleepAnalysisAwake),
                @"HKCategoryValueSleepAnalysisAsleepCore":@(HKCategoryValueSleepAnalysisAsleepCore),
                @"HKCategoryValueSleepAnalysisAsleepDeep":@(HKCategoryValueSleepAnalysisAsleepDeep),
                @"HKCategoryValueSleepAnalysisAsleepREM":@(HKCategoryValueSleepAnalysisAsleepREM)
            }
        };
    } else {
        map = @{
              @"HKCategoryTypeIdentifierSleepAnalysis":@{
                @"HKCategoryValueSleepAnalysisInBed":@(HKCategoryValueSleepAnalysisInBed),
                @"HKCategoryValueSleepAnalysisAsleep":@(HKCategoryValueSleepAnalysisAsleep),
                @"HKCategoryValueSleepAnalysisAwake":@(HKCategoryValueSleepAnalysisAwake),
            }
        };
    }
    
    NSDictionary * valueMap = map[type.identifier];
    if (!valueMap) {
      return HKCategoryValueNotApplicable;
    }
    return valueMap[categoryValue];
}

/**
 * Query HealthKit to get correlation data within a specified date range
 *
 * @param startDate
 * @param endDate
 * @param correlationTypeString
 * @param objects
 * @param metadata
 * @param error
 * @return
 */
- (HKCorrelation *)getHKCorrelationWithStartDate:(NSDate *)startDate
                                         endDate:(NSDate *)endDate
                           correlationTypeString:(NSString *)correlationTypeString
                                         objects:(NSSet *)objects
                                        metadata:(NSDictionary *)metadata
                                           error:(NSError **)error {
#ifdef HKPLUGIN_DEBUG
    NSLog(@"correlation type is %@", correlationTypeString);
#endif

    HKCorrelationType *correlationType = [HKCorrelationType correlationTypeForIdentifier:correlationTypeString];
    if (correlationType == nil) {
        if (error != nil) {
            *error = [NSError errorWithDomain:HKPluginError code:0 userInfo:@{NSLocalizedDescriptionKey: @"correlation type string is invalid"}];
        }

        return nil;
    }

    return [HKCorrelation correlationWithType:correlationType startDate:startDate endDate:endDate objects:objects metadata:metadata];
}

/**
 * Trigger a generic error callback
 *
 * @param message   *NSString
 * @param command   *CDVInvokedUrlCommand
 * @param delegate  id<CDVCommandDelegate>
 */
+ (void)triggerErrorCallbackWithMessage: (NSString *) message command: (CDVInvokedUrlCommand *) command delegate: (id<CDVCommandDelegate>) delegate {
    @autoreleasepool {
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:message];
        [delegate sendPluginResult:result callbackId:command.callbackId];
    }
}

@end

/**
 * Implementation of NSDictionary (RequiredKey)
 */
#pragma mark NSDictionary (RequiredKey)

@implementation NSDictionary (RequiredKey)

/**
 *
 * @param keys  *NSArray
 * @param error **NSError
 * @return      BOOL
 */
- (BOOL)hasAllRequiredKeys:(NSArray<NSString *> *)keys error:(NSError **)error {
    NSMutableArray *missing = [NSMutableArray arrayWithCapacity:0];

    for (NSString *key in keys) {
        if (self[key] == nil) {
            [missing addObject:key];
        }
    }

    if (missing.count == 0) {
        return YES;
    }

    if (error != nil) {
        NSString *errMsg = [NSString stringWithFormat:@"required value(s) -%@- is missing from dictionary %@", [missing componentsJoinedByString:@", "], [self description]];
        *error = [NSError errorWithDomain:HKPluginError code:0 userInfo:@{NSLocalizedDescriptionKey: errMsg}];
    }

    return NO;
}

@end

/**
 * Implementation of public interface
 * **************************************************************************************
 */
#pragma mark Public Interface

@implementation HealthKit

/**
 * Get shared health store
 *
 * @return *HKHealthStore
 */
+ (HKHealthStore *)sharedHealthStore {
    __strong static HKHealthStore *store = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        store = [[HKHealthStore alloc] init];
    });

    return store;
}

/**
 * Tell delegate whether or not health data is available
 *
 * @param command *CDVInvokedUrlCommand
 */
- (void)available:(CDVInvokedUrlCommand *)command {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:[HKHealthStore isHealthDataAvailable]];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

/**
 * Opens the Health app
 *
 * @param command *CDVInvokedUrlCommand
 */
- (void)openHealthSettings:(CDVInvokedUrlCommand *)command {
    CDVPluginResult* pluginResult = nil;
        
        NSString* scheme = @"x-apple-health://";
        
        if ([[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:scheme]]) {
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:scheme] options:@{} completionHandler:nil];
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:(true)];
        }
        else {
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsBool:(false)];
        }
        
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}


/**
 * Request authorization for read and/or write permissions
 *
 * @param command *CDVInvokedUrlCommand
 */
- (void)requestAuthorization:(CDVInvokedUrlCommand *)command {
    NSMutableDictionary *args = command.arguments[0];

    // read types
    NSArray<NSString *> *readTypes = args[HKPluginKeyReadTypes];
    NSMutableSet *readDataTypes = [[NSMutableSet alloc] init];

    for (NSString *elem in readTypes) {
#ifdef HKPLUGIN_DEBUG
        NSLog(@"Requesting read permissions for %@", elem);
#endif
        HKObjectType *type = nil;

        if ([elem isEqual:@"HKWorkoutTypeIdentifier"]) {
            type = [HKObjectType workoutType];
        } else if ([elem isEqual:@"HKWorkoutRouteType"]) {
            type = [HKSeriesType workoutRouteType];
        } else {
            type = [HealthKit getHKObjectType:elem];
        }

        if (type == nil) {
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"readTypes contains an invalid value"];
            [result setKeepCallbackAsBool:YES];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            // not returning deliberately to be future proof; other permissions are still asked
        } else {
            [readDataTypes addObject:type];
        }
    }

    // write types
    NSArray<NSString *> *writeTypes = args[HKPluginKeyWriteTypes];
    NSMutableSet *writeDataTypes = [[NSMutableSet alloc] init];

    for (NSString *elem in writeTypes) {
#ifdef HKPLUGIN_DEBUG
        NSLog(@"Requesting write permission for %@", elem);
#endif
        HKObjectType *type = nil;

        if ([elem isEqual:@"HKWorkoutTypeIdentifier"]) {
            type = [HKObjectType workoutType];
        } else {
            type = [HealthKit getHKObjectType:elem];
        }

        if (type == nil) {
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"writeTypes contains an invalid value"];
            [result setKeepCallbackAsBool:YES];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            // not returning deliberately to be future proof; other permissions are still asked
        } else {
            [writeDataTypes addObject:type];
        }
    }

    [[HealthKit sharedHealthStore] requestAuthorizationToShareTypes:writeDataTypes readTypes:readDataTypes completion:^(BOOL success, NSError *error) {
        if (success) {
            dispatch_sync(dispatch_get_main_queue(), ^{
                CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
                [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            });
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error.localizedDescription];
                [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            });
        }
    }];
}

/**
 * Check the authorization status for a specified permission
 *
 * @param command *CDVInvokedUrlCommand
 */
- (void)checkAuthStatus:(CDVInvokedUrlCommand *)command {
    // If status = denied, prompt user to go to settings or the Health app
    // Note that read access is not reflected. We're not allowed to know
    // if a user grants/denies read access, *only* write access.
    NSMutableDictionary *args = command.arguments[0];
    NSString *checkType = args[HKPluginKeyType];
    HKObjectType *type;

    if ([checkType isEqual:@"HKWorkoutTypeIdentifier"]) {
        type = [HKObjectType workoutType];
    } else {
        type = [HealthKit getHKObjectType:checkType];
    }

    __block HealthKit *bSelf = self;
    [self checkAuthStatusWithCallbackId:command.callbackId forType:type andCompletion:^(CDVPluginResult *result, NSString *callbackId) {
        [bSelf.commandDelegate sendPluginResult:result callbackId:callbackId];
    }];
}

/**
 * Save workout data
 *
 * @param command *CDVInvokedUrlCommand
 */
- (void)saveWorkout:(CDVInvokedUrlCommand *)command {
    NSMutableDictionary *args = command.arguments[0];

    NSString *activityType = args[@"activityType"];
    NSString *quantityType = args[@"quantityType"]; // TODO verify this value

    HKWorkoutActivityType activityTypeEnum = [WorkoutActivityConversion convertStringToHKWorkoutActivityType:activityType];

    BOOL requestReadPermission = (args[@"requestReadPermission"] == nil || [args[@"requestReadPermission"] boolValue]);
    BOOL *cycling = (args[@"cycling"] != nil && [args[@"cycling"] boolValue]);

    // optional energy
    NSNumber *energy = args[@"energy"];
    NSString *energyUnit = args[@"energyUnit"];
    HKQuantity *nrOfEnergyUnits = nil;
    if (energy != nil && energy != (id) [NSNull null]) { // better safe than sorry
        HKUnit *preferredEnergyUnit = [HealthKit getUnit:energyUnit expected:@"HKEnergyUnit"];
        if (preferredEnergyUnit == nil) {
            [HealthKit triggerErrorCallbackWithMessage:@"invalid energyUnit is passed" command:command delegate:self.commandDelegate];
            return;
        }
        nrOfEnergyUnits = [HKQuantity quantityWithUnit:preferredEnergyUnit doubleValue:energy.doubleValue];
    }

    // optional distance
    NSNumber *distance = args[@"distance"];
    NSString *distanceUnit = args[@"distanceUnit"];
    HKQuantity *nrOfDistanceUnits = nil;
    if (distance != nil && distance != (id) [NSNull null]) { // better safe than sorry
        HKUnit *preferredDistanceUnit = [HealthKit getUnit:distanceUnit expected:@"HKLengthUnit"];
        if (preferredDistanceUnit == nil) {
            [HealthKit triggerErrorCallbackWithMessage:@"invalid distanceUnit is passed" command:command delegate:self.commandDelegate];
            return;
        }
        nrOfDistanceUnits = [HKQuantity quantityWithUnit:preferredDistanceUnit doubleValue:distance.doubleValue];
    }

    int duration = 0;
    NSDate *startDate = [NSDate dateWithTimeIntervalSince1970:[args[HKPluginKeyStartDate] doubleValue]];


    NSDate *endDate;
    if (args[@"duration"] != nil) {
        duration = [args[@"duration"] intValue];
        endDate = [NSDate dateWithTimeIntervalSince1970:startDate.timeIntervalSince1970 + duration];
    } else if (args[HKPluginKeyEndDate] != nil) {
        endDate = [NSDate dateWithTimeIntervalSince1970:[args[HKPluginKeyEndDate] doubleValue]];
    } else {
        [HealthKit triggerErrorCallbackWithMessage:@"no duration or endDate is set" command:command delegate:self.commandDelegate];
        return;
    }

    NSSet *types = [NSSet setWithObjects:
            [HKWorkoutType workoutType],
            [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierActiveEnergyBurned],
            [HKQuantityType quantityTypeForIdentifier:quantityType],
                    nil];
    [[HealthKit sharedHealthStore] requestAuthorizationToShareTypes:types readTypes:(requestReadPermission ? types : nil) completion:^(BOOL success_requestAuth, NSError *error) {
        __block HealthKit *bSelf = self;
        if (!success_requestAuth) {
            dispatch_sync(dispatch_get_main_queue(), ^{
                [HealthKit triggerErrorCallbackWithMessage:error.localizedDescription command:command delegate:bSelf.commandDelegate];
            });
        } else {
            HKWorkout *workout = [HKWorkout workoutWithActivityType:activityTypeEnum
                                                          startDate:startDate
                                                            endDate:endDate
                                                           duration:0 // the diff between start and end is used
                                                  totalEnergyBurned:nrOfEnergyUnits
                                                      totalDistance:nrOfDistanceUnits
                                                           metadata:nil]; // TODO find out if needed

            [[HealthKit sharedHealthStore] saveObject:workout withCompletion:^(BOOL success_save, NSError *innerError) {
                if (success_save) {
                    // now store the samples, so it shows up in the health app as well (pass this in as an option?)
                    if (energy != nil || distance != nil) {
                        HKQuantitySample *sampleDistance = nil;
                        if(distance != nil) {
                            if(cycling != nil && cycling){
                                sampleDistance = [HKQuantitySample quantitySampleWithType:[HKQuantityType quantityTypeForIdentifier:
                                                HKQuantityTypeIdentifierDistanceCycling]
                                                                                            quantity:nrOfDistanceUnits
                                                                                            startDate:startDate
                                                                                                endDate:endDate];
                            } else {
                                sampleDistance = [HKQuantitySample quantitySampleWithType:[HKQuantityType quantityTypeForIdentifier:
                                                HKQuantityTypeIdentifierDistanceWalkingRunning]
                                                                                            quantity:nrOfDistanceUnits
                                                                                            startDate:startDate
                                                                                                endDate:endDate];

                            }
                        }
                        HKQuantitySample *sampleCalories = nil;
                        if(energy != nil) {
                            sampleCalories = [HKQuantitySample quantitySampleWithType:[HKQuantityType     quantityTypeForIdentifier:
                                            HKQuantityTypeIdentifierActiveEnergyBurned]
                                                                                           quantity:nrOfEnergyUnits
                                                                                          startDate:startDate
                                                                                            endDate:endDate];
                        }
                         NSArray *samples = nil;
                         if (energy != nil &&  distance != nil) { 
                            // both distance and energy
                            samples = @[sampleDistance, sampleCalories];
                         } else if (energy != nil &&  distance == nil) { 
                            // only energy
                            samples = @[sampleCalories];
                         } else if (energy == nil &&  distance != nil) {
                            // only distance
                            samples = @[sampleDistance];
                         }
                        

                        [[HealthKit sharedHealthStore] addSamples:samples toWorkout:workout completion:^(BOOL success_addSamples, NSError *mostInnerError) {
                            if (success_addSamples) {
                                dispatch_sync(dispatch_get_main_queue(), ^{
                                    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
                                    [bSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
                                });
                            } else {
                                dispatch_sync(dispatch_get_main_queue(), ^{
                                    [HealthKit triggerErrorCallbackWithMessage:mostInnerError.localizedDescription command:command delegate:bSelf.commandDelegate];
                                });
                            }
                        }];
                    } else {
                      // no samples, all OK then!
                      dispatch_sync(dispatch_get_main_queue(), ^{
                          CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
                          [bSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
                      });
                    }
                } else {
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        [HealthKit triggerErrorCallbackWithMessage:innerError.localizedDescription command:command delegate:bSelf.commandDelegate];
                    });
                }
            }];
        }
    }];
}

/**
 * Find workout data
 *
 * @param command *CDVInvokedUrlCommand
 */
- (void)findWorkouts:(CDVInvokedUrlCommand *)command {
    NSMutableDictionary *args = command.arguments[0];
    NSPredicate *workoutPredicate = nil;
    // TODO if a specific workouttype was passed, use that
    //  if (false) {
    //    workoutPredicate = [HKQuery predicateForWorkoutsWithWorkoutActivityType:HKWorkoutActivityTypeCycling];
    //  }

    BOOL *includeCalories = (args[@"includeCalories"] != nil && [args[@"includeCalories"] boolValue]);
    BOOL *includeDistance = (args[@"includeDistance"] != nil && [args[@"includeDistance"] boolValue]);

    

    NSSet *types = [NSSet setWithObjects:[HKWorkoutType workoutType], nil];
    [[HealthKit sharedHealthStore] requestAuthorizationToShareTypes:nil readTypes:types completion:^(BOOL success, NSError *error) {
        __block HealthKit *bSelf = self;
        if (!success) {
            dispatch_sync(dispatch_get_main_queue(), ^{
                [HealthKit triggerErrorCallbackWithMessage:error.localizedDescription command:command delegate:bSelf.commandDelegate];
            });
        } else {


            HKSampleQuery *query = [[HKSampleQuery alloc] initWithSampleType:[HKWorkoutType workoutType] predicate:workoutPredicate limit:HKObjectQueryNoLimit sortDescriptors:nil resultsHandler:^(HKSampleQuery *sampleQuery, NSArray *results, NSError *innerError) {
                if (innerError) {
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        [HealthKit triggerErrorCallbackWithMessage:innerError.localizedDescription command:command delegate:bSelf.commandDelegate];
                    });
                } else {
                    NSMutableArray *finalResults = [[NSMutableArray alloc] initWithCapacity:results.count];

                    for (HKWorkout *workout in results) {
                        NSString *workoutActivity = [WorkoutActivityConversion convertHKWorkoutActivityTypeToString:workout.workoutActivityType];

                        // iOS 9 moves the source property to a collection of revisions
                        HKSource *source = nil;
                        if ([workout respondsToSelector:@selector(sourceRevision)]) {
                            source = [[workout valueForKey:@"sourceRevision"] valueForKey:@"source"];
                        } else {
                            //@TODO Update deprecated API call
                            source = workout.source;
                        }
                        NSMutableDictionary *entry;
                        entry = [
                                @{
                                        @"duration": @(workout.duration),
                                        HKPluginKeyStartDate: [HealthKit stringFromDate:workout.startDate],
                                        HKPluginKeyEndDate: [HealthKit stringFromDate:workout.endDate],
                                        HKPluginKeySourceBundleId: source.bundleIdentifier,
                                        HKPluginKeySourceName: source.name,
                                        @"activityType": workoutActivity,
                                        @"UUID": [workout.UUID UUIDString]
                                } mutableCopy
                            ];

                        if(includeCalories != nil && includeCalories) {
                            // Parse totalEnergyBurned in kilocalories
                            double cals = [workout.totalEnergyBurned doubleValueForUnit:[HKUnit kilocalorieUnit]];
                            NSString *calories = [[NSNumber numberWithDouble:cals] stringValue];

                            entry[@"energy"] = calories;
                        }
                        if(includeDistance != nil && includeDistance) {
                            double meters = [workout.totalDistance doubleValueForUnit:[HKUnit meterUnit]];
                            NSString *metersString = [NSString stringWithFormat:@"%ld", (long) meters];

                            entry[@"distance"] = metersString;
                        }

                        [finalResults addObject:entry];
                    }

                    dispatch_sync(dispatch_get_main_queue(), ^{
                        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:finalResults];
                        [bSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
                    });
                }
            }];
            [[HealthKit sharedHealthStore] executeQuery:query];
        }
    }];
}

/**
 * Save weight data
 *
 * @param command *CDVInvokedUrlCommand
 */
- (void)saveWeight:(CDVInvokedUrlCommand *)command {
    NSMutableDictionary *args = command.arguments[0];
    NSString *unit = args[HKPluginKeyUnit];
    NSNumber *amount = args[HKPluginKeyAmount];
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:[args[@"date"] doubleValue]];
    BOOL requestReadPermission = (args[@"requestReadPermission"] == nil || [args[@"requestReadPermission"] boolValue]);

    if (amount == nil) {
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"no amount was set"];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        return;
    }

    HKUnit *preferredUnit = [HealthKit getUnit:unit expected:@"HKMassUnit"];
    if (preferredUnit == nil) {
        [HealthKit triggerErrorCallbackWithMessage:@"invalid unit is passed" command:command delegate:self.commandDelegate];
        return;
    }

    HKQuantityType *weightType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierBodyMass];
    NSSet *requestTypes = [NSSet setWithObjects:weightType, nil];
    __block HealthKit *bSelf = self;
    [[HealthKit sharedHealthStore] requestAuthorizationToShareTypes:requestTypes readTypes:(requestReadPermission ? requestTypes : nil) completion:^(BOOL success, NSError *error) {
        if (success) {
            HKQuantity *weightQuantity = [HKQuantity quantityWithUnit:preferredUnit doubleValue:[amount doubleValue]];
            HKQuantitySample *weightSample = [HKQuantitySample quantitySampleWithType:weightType quantity:weightQuantity startDate:date endDate:date];
            [[HealthKit sharedHealthStore] saveObject:weightSample withCompletion:^(BOOL success_save, NSError *errorInner) {
                if (success_save) {
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
                        [bSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
                    });
                } else {
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        [HealthKit triggerErrorCallbackWithMessage:errorInner.localizedDescription command:command delegate:bSelf.commandDelegate];
                    });
                }
            }];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                [HealthKit triggerErrorCallbackWithMessage:error.localizedDescription command:command delegate:bSelf.commandDelegate];
            });
        }
    }];
}

/**
 * Read weight data
 *
 * @param command *CDVInvokedUrlCommand
 */
- (void)readWeight:(CDVInvokedUrlCommand *)command {
    NSDictionary *args = command.arguments[0];
    NSString *unit = args[HKPluginKeyUnit];
    BOOL requestWritePermission = (args[@"requestWritePermission"] == nil || [args[@"requestWritePermission"] boolValue]);

    HKUnit *preferredUnit = [HealthKit getUnit:unit expected:@"HKMassUnit"];
    if (preferredUnit == nil) {
        [HealthKit triggerErrorCallbackWithMessage:@"invalid unit is passed" command:command delegate:self.commandDelegate];
        return;
    }

    // Query to get the user's latest weight, if it exists.
    HKQuantityType *weightType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierBodyMass];
    NSSet *requestTypes = [NSSet setWithObjects:weightType, nil];
    // always ask for read and write permission if the app uses both, because granting read will remove write for the same type :(
    [[HealthKit sharedHealthStore] requestAuthorizationToShareTypes:(requestWritePermission ? requestTypes : nil) readTypes:requestTypes completion:^(BOOL success, NSError *error) {
        __block HealthKit *bSelf = self;
        if (success) {
            [[HealthKit sharedHealthStore] aapl_mostRecentQuantitySampleOfType:weightType predicate:nil completion:^(HKQuantity *mostRecentQuantity, NSDate *mostRecentDate, NSError *errorInner) {
                if (mostRecentQuantity) {
                    double usersWeight = [mostRecentQuantity doubleValueForUnit:preferredUnit];
                    NSMutableDictionary *entry = [
                            @{
                                    HKPluginKeyValue: @(usersWeight),
                                    HKPluginKeyUnit: unit,
                                    @"date": [HealthKit stringFromDate:mostRecentDate]
                            } mutableCopy
                    ];

                    //@TODO formerly dispatch_async
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:entry];
                        [bSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
                    });
                } else {
                    //@TODO formerly dispatch_async
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        NSString *errorDescription = ((errorInner.localizedDescription == nil) ? @"no data" : errorInner.localizedDescription);
                        [HealthKit triggerErrorCallbackWithMessage:errorDescription command:command delegate:bSelf.commandDelegate];
                    });
                }
            }];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                [HealthKit triggerErrorCallbackWithMessage:error.localizedDescription command:command delegate:bSelf.commandDelegate];
            });
        }
    }];
}

/**
 * Save height data
 *
 * @param command *CDVInvokedUrlCommand
 */
- (void)saveHeight:(CDVInvokedUrlCommand *)command {
    NSDictionary *args = command.arguments[0];
    NSString *unit = args[HKPluginKeyUnit];
    NSNumber *amount = args[HKPluginKeyAmount];
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:[args[@"date"] doubleValue]];
    BOOL requestReadPermission = (args[@"requestReadPermission"] == nil || [args[@"requestReadPermission"] boolValue]);

    if (amount == nil) {
        [HealthKit triggerErrorCallbackWithMessage:@"no amount is set" command:command delegate:self.commandDelegate];
        return;
    }

    HKUnit *preferredUnit = [HealthKit getUnit:unit expected:@"HKLengthUnit"];
    if (preferredUnit == nil) {
        [HealthKit triggerErrorCallbackWithMessage:@"invalid unit is passed" command:command delegate:self.commandDelegate];
        return;
    }

    HKQuantityType *heightType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierHeight];
    NSSet *requestTypes = [NSSet setWithObjects:heightType, nil];
    [[HealthKit sharedHealthStore] requestAuthorizationToShareTypes:requestTypes readTypes:(requestReadPermission ? requestTypes : nil) completion:^(BOOL success_requestAuth, NSError *error) {
        __block HealthKit *bSelf = self;
        if (success_requestAuth) {
            HKQuantity *heightQuantity = [HKQuantity quantityWithUnit:preferredUnit doubleValue:[amount doubleValue]];
            HKQuantitySample *heightSample = [HKQuantitySample quantitySampleWithType:heightType quantity:heightQuantity startDate:date endDate:date];
            [[HealthKit sharedHealthStore] saveObject:heightSample withCompletion:^(BOOL success_save, NSError *innerError) {
                if (success_save) {
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
                        [bSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
                    });
                } else {
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        [HealthKit triggerErrorCallbackWithMessage:innerError.localizedDescription command:command delegate:bSelf.commandDelegate];
                    });
                }
            }];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                [HealthKit triggerErrorCallbackWithMessage:error.localizedDescription command:command delegate:bSelf.commandDelegate];
            });
        }
    }];
}

/**
 * Read height data
 *
 * @param command *CDVInvokedUrlCommand
 */
- (void)readHeight:(CDVInvokedUrlCommand *)command {
    NSDictionary *args = command.arguments[0];
    NSString *unit = args[HKPluginKeyUnit];
    BOOL requestWritePermission = (args[@"requestWritePermission"] == nil || [args[@"requestWritePermission"] boolValue]);

    HKUnit *preferredUnit = [HealthKit getUnit:unit expected:@"HKLengthUnit"];
    if (preferredUnit == nil) {
        [HealthKit triggerErrorCallbackWithMessage:@"invalid unit is passed" command:command delegate:self.commandDelegate];
        return;
    }

    // Query to get the user's latest height, if it exists.
    HKQuantityType *heightType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierHeight];
    NSSet *requestTypes = [NSSet setWithObjects:heightType, nil];
    // always ask for read and write permission if the app uses both, because granting read will remove write for the same type :(
    [[HealthKit sharedHealthStore] requestAuthorizationToShareTypes:(requestWritePermission ? requestTypes : nil) readTypes:requestTypes completion:^(BOOL success, NSError *error) {
        __block HealthKit *bSelf = self;
        if (success) {
            [[HealthKit sharedHealthStore] aapl_mostRecentQuantitySampleOfType:heightType predicate:nil completion:^(HKQuantity *mostRecentQuantity, NSDate *mostRecentDate, NSError *errorInner) { // TODO use
                if (mostRecentQuantity) {
                    double usersHeight = [mostRecentQuantity doubleValueForUnit:preferredUnit];
                    NSMutableDictionary *entry = [
                            @{
                                    HKPluginKeyValue: @(usersHeight),
                                    HKPluginKeyUnit: unit,
                                    @"date": [HealthKit stringFromDate:mostRecentDate]
                            } mutableCopy
                    ];

                    //@TODO formerly dispatch_async
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:entry];
                        [bSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
                    });
                } else {
                    //@TODO formerly dispatch_async
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        NSString *errorDescritption = ((errorInner.localizedDescription == nil) ? @"no data" : errorInner.localizedDescription);
                        [HealthKit triggerErrorCallbackWithMessage:errorDescritption command:command delegate:bSelf.commandDelegate];
                    });
                }
            }];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                [HealthKit triggerErrorCallbackWithMessage:error.localizedDescription command:command delegate:bSelf.commandDelegate];
            });
        }
    }];
}

/**
 * Read gender data
 *
 * @param command *CDVInvokedUrlCommand
 */
- (void)readGender:(CDVInvokedUrlCommand *)command {
    HKCharacteristicType *genderType = [HKObjectType characteristicTypeForIdentifier:HKCharacteristicTypeIdentifierBiologicalSex];
    [[HealthKit sharedHealthStore] requestAuthorizationToShareTypes:nil readTypes:[NSSet setWithObjects:genderType, nil] completion:^(BOOL success, NSError *error) {
        __block HealthKit *bSelf = self;
        if (success) {
            HKBiologicalSexObject *sex = [[HealthKit sharedHealthStore] biologicalSexWithError:&error];
            if (sex != nil) {

                NSString *gender = nil;
                switch (sex.biologicalSex) {
                    case HKBiologicalSexMale:
                        gender = @"male";
                        break;
                    case HKBiologicalSexFemale:
                        gender = @"female";
                        break;
                    case HKBiologicalSexOther:
                        gender = @"other";
                        break;
                    default:
                        gender = @"unknown";
                }

                CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:gender];
                [bSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            } else {
                [HealthKit triggerErrorCallbackWithMessage:error.localizedDescription command:command delegate:bSelf.commandDelegate];
            }
        }
    }];
}

/**
 * Read Fitzpatrick Skin Type Data
 *
 * @param command *CDVInvokedUrlCommand
 */
- (void)readFitzpatrickSkinType:(CDVInvokedUrlCommand *)command {
    // fp skintype is available since iOS 9, so we need to check it
    if (![[HealthKit sharedHealthStore] respondsToSelector:@selector(fitzpatrickSkinTypeWithError:)]) {
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"not available on this device"];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        return;
    }

    HKCharacteristicType *type = [HKObjectType characteristicTypeForIdentifier:HKCharacteristicTypeIdentifierFitzpatrickSkinType];
    [[HealthKit sharedHealthStore] requestAuthorizationToShareTypes:nil readTypes:[NSSet setWithObjects:type, nil] completion:^(BOOL success, NSError *error) {
        __block HealthKit *bSelf = self;
        if (success) {
            HKFitzpatrickSkinTypeObject *skinType = [[HealthKit sharedHealthStore] fitzpatrickSkinTypeWithError:&error];
            if (skinType != nil) {

                NSString *skin = nil;
                switch (skinType.skinType) {
                    case HKFitzpatrickSkinTypeI:
                        skin = @"I";
                        break;
                    case HKFitzpatrickSkinTypeII:
                        skin = @"II";
                        break;
                    case HKFitzpatrickSkinTypeIII:
                        skin = @"III";
                        break;
                    case HKFitzpatrickSkinTypeIV:
                        skin = @"IV";
                        break;
                    case HKFitzpatrickSkinTypeV:
                        skin = @"V";
                        break;
                    case HKFitzpatrickSkinTypeVI:
                        skin = @"VI";
                        break;
                    default:
                        skin = @"unknown";
                }

                CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:skin];
                [bSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            } else {
                [HealthKit triggerErrorCallbackWithMessage:error.localizedDescription command:command delegate:bSelf.commandDelegate];
            }
        }
    }];
}

/**
 * Read blood type data
 *
 * @param command *CDVInvokedUrlCommand
 */
- (void)readBloodType:(CDVInvokedUrlCommand *)command {
    HKCharacteristicType *bloodType = [HKObjectType characteristicTypeForIdentifier:HKCharacteristicTypeIdentifierBloodType];
    [[HealthKit sharedHealthStore] requestAuthorizationToShareTypes:nil readTypes:[NSSet setWithObjects:bloodType, nil] completion:^(BOOL success, NSError *error) {
        __block HealthKit *bSelf = self;
        if (success) {
            HKBloodTypeObject *innerBloodType = [[HealthKit sharedHealthStore] bloodTypeWithError:&error];
            if (innerBloodType != nil) {
                NSString *bt = nil;

                switch (innerBloodType.bloodType) {
                    case HKBloodTypeAPositive:
                        bt = @"A+";
                        break;
                    case HKBloodTypeANegative:
                        bt = @"A-";
                        break;
                    case HKBloodTypeBPositive:
                        bt = @"B+";
                        break;
                    case HKBloodTypeBNegative:
                        bt = @"B-";
                        break;
                    case HKBloodTypeABPositive:
                        bt = @"AB+";
                        break;
                    case HKBloodTypeABNegative:
                        bt = @"AB-";
                        break;
                    case HKBloodTypeOPositive:
                        bt = @"O+";
                        break;
                    case HKBloodTypeONegative:
                        bt = @"O-";
                        break;
                    default:
                        bt = @"unknown";
                }

                CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:bt];
                [bSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            } else {
                [HealthKit triggerErrorCallbackWithMessage:error.localizedDescription command:command delegate:bSelf.commandDelegate];
            }
        }
    }];
}

/**
 * Read date of birth data
 *
 * @param command *CDVInvokedUrlCommand
 */
- (void)readDateOfBirth:(CDVInvokedUrlCommand *)command {
    HKCharacteristicType *birthdayType = [HKObjectType characteristicTypeForIdentifier:HKCharacteristicTypeIdentifierDateOfBirth];
    [[HealthKit sharedHealthStore] requestAuthorizationToShareTypes:nil readTypes:[NSSet setWithObjects:birthdayType, nil] completion:^(BOOL success, NSError *error) {
        __block HealthKit *bSelf = self;
        if (success) {
            NSDate *dateOfBirth = [[HealthKit sharedHealthStore] dateOfBirthWithError:&error];
            if (dateOfBirth) {
                CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:[HealthKit stringFromDate:dateOfBirth]];
                [bSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            } else {
                [HealthKit triggerErrorCallbackWithMessage:error.localizedDescription command:command delegate:bSelf.commandDelegate];
            }
        }
    }];
}

/**
 * Monitor a specified sample type
 *
 * @param command *CDVInvokedUrlCommand
 */
- (void)monitorSampleType:(CDVInvokedUrlCommand *)command {
    NSDictionary *args = command.arguments[0];
    NSString *sampleTypeString = args[HKPluginKeySampleType];
    HKSampleType *type = [HealthKit getHKSampleType:sampleTypeString];
    HKUpdateFrequency updateFrequency = HKUpdateFrequencyImmediate;
    if (type == nil) {
        [HealthKit triggerErrorCallbackWithMessage:@"sampleType was invalid" command:command delegate:self.commandDelegate];
        return;
    }

    // TODO use this an an anchor for an achored query
    //__block int *anchor = 0;
#ifdef HKPLUGIN_DEBUG
    NSLog(@"Setting up ObserverQuery");
#endif

    HKObserverQuery *query;
    query = [[HKObserverQuery alloc] initWithSampleType:type
                                              predicate:nil
                                          updateHandler:^(HKObserverQuery *observerQuery,
                                                  HKObserverQueryCompletionHandler handler,
                                                  NSError *error) {
                                              __block HealthKit *bSelf = self;
                                              if (error) {
                                                  handler();
                                                  dispatch_sync(dispatch_get_main_queue(), ^{
                                                      [HealthKit triggerErrorCallbackWithMessage:error.localizedDescription command:command delegate:bSelf.commandDelegate];
                                                  });
                                              } else {
                                                  handler();
#ifdef HKPLUGIN_DEBUG
                                                  NSLog(@"HealthKit plugin received a monitorSampleType, passing it to JS.");
#endif
                                                  // TODO using a anchored qery to return the new and updated values.
                                                  // Until then use querySampleType({limit=1, ascending="T", endDate=new Date()}) to return the last result

                                                  // Issue #47: commented this block since it resulted in callbacks not being delivered while the app was in the background
                                                  //dispatch_sync(dispatch_get_main_queue(), ^{
                                                  CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:sampleTypeString];
                                                  [result setKeepCallbackAsBool:YES];
                                                  [bSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
                                                  //});
                                              }
                                          }];

    // Make sure we get the updated immediately
    [[HealthKit sharedHealthStore] enableBackgroundDeliveryForType:type frequency:updateFrequency withCompletion:^(BOOL success, NSError *error) {
#ifdef HKPLUGIN_DEBUG
        if (success) {
            NSLog(@"Background devliery enabled %@", sampleTypeString);
        } else {
            NSLog(@"Background delivery not enabled for %@ because of %@", sampleTypeString, error);
        }
        NSLog(@"Executing ObserverQuery");
#endif
        [[HealthKit sharedHealthStore] executeQuery:query];
        // TODO provide some kind of callback to stop monitoring this value, store the query in some kind of WeakHashSet equilavent?
    }];
};

/**
 * Get the sum of a specified quantity type
 *
 * @param command *CDVInvokedUrlCommand
 */
- (void)sumQuantityType:(CDVInvokedUrlCommand *)command {
    NSDictionary *args = command.arguments[0];

    NSDate *startDate = [NSDate dateWithTimeIntervalSince1970:[args[HKPluginKeyStartDate] longValue]];
    NSDate *endDate = [NSDate dateWithTimeIntervalSince1970:[args[HKPluginKeyEndDate] longValue]];
    NSString *sampleTypeString = args[HKPluginKeySampleType];
    NSString *unitString = args[HKPluginKeyUnit];
    HKQuantityType *type = [HKObjectType quantityTypeForIdentifier:sampleTypeString];
    HKStatisticsOptions sumOptions = HKStatisticsOptionCumulativeSum;


    if (type == nil) {
        [HealthKit triggerErrorCallbackWithMessage:@"sampleType is invalid" command:command delegate:self.commandDelegate];
        return;
    } else if ([sampleTypeString isEqualToString:@"HKQuantityTypeIdentifierHeartRate"]) {
        sumOptions = HKStatisticsOptionDiscreteAverage | HKStatisticsOptionDiscreteMin | HKStatisticsOptionDiscreteMax;

    } else { //HKQuantityTypeIdentifierStepCount, etc...
        sumOptions = HKStatisticsOptionCumulativeSum;
    }

    NSPredicate *predicate = [HKQuery predicateForSamplesWithStartDate:startDate endDate:endDate options:HKQueryOptionStrictStartDate];
    HKStatisticsQuery *query;
    HKUnit *unit = ((unitString != nil) ? [HKUnit unitFromString:unitString] : [HKUnit countUnit]);
    query = [[HKStatisticsQuery alloc] initWithQuantityType:type
                                    quantitySamplePredicate:predicate
                                                    options:sumOptions
                                          completionHandler:^(HKStatisticsQuery *statisticsQuery,
                                                  HKStatistics *result,
                                                  NSError *error) {
        if ([sampleTypeString isEqualToString:@"HKQuantityTypeIdentifierHeartRate"]) {
            HKQuantity *avg = [result averageQuantity];
            HKQuantity *min = [result minimumQuantity];
            HKQuantity *max = [result maximumQuantity];
            NSMutableDictionary *stats = [NSMutableDictionary dictionary];
            stats[@"average"] = @([avg doubleValueForUnit:unit]);
            stats[@"min"] = @([min doubleValueForUnit:unit]);
            stats[@"max"] = @([max doubleValueForUnit:unit]);
            
            CDVPluginResult *response = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:stats];
            [self.commandDelegate sendPluginResult:response callbackId:command.callbackId];
        } else { //HKQuantityTypeIdentifierStepCount, etc...
            HKQuantity *sum = [result sumQuantity];
            CDVPluginResult *response = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDouble:[sum doubleValueForUnit:unit]];
            [self.commandDelegate sendPluginResult:response callbackId:command.callbackId];
        }
                                          }];

    [[HealthKit sharedHealthStore] executeQuery:query];
}

/**
 * Query a specified sample type
 *
 * @param command *CDVInvokedUrlCommand
 */
- (void)querySampleType:(CDVInvokedUrlCommand *)command {
    NSDictionary *args = command.arguments[0];
    NSDate *startDate = [NSDate dateWithTimeIntervalSince1970:[args[HKPluginKeyStartDate] longValue]];
    NSDate *endDate = [NSDate dateWithTimeIntervalSince1970:[args[HKPluginKeyEndDate] longValue]];
    NSString *sampleTypeString = args[HKPluginKeySampleType];
    NSString *unitString = args[HKPluginKeyUnit];
    NSUInteger limit = ((args[@"limit"] != nil) ? [args[@"limit"] unsignedIntegerValue] : 1000);
    BOOL ascending = (args[@"ascending"] != nil && [args[@"ascending"] boolValue]);

    HKSampleType *type = [HealthKit getHKSampleType:sampleTypeString];
    if (type == nil) {
        [HealthKit triggerErrorCallbackWithMessage:@"sampleType was invalid" command:command delegate:self.commandDelegate];
        return;
    }
    HKUnit *unit = nil;
    if (unitString != nil) {
        if ([unitString isEqualToString:@"mmol/L"]) {
            // @see https://stackoverflow.com/a/30196642/1214598
            unit = [[HKUnit moleUnitWithMetricPrefix:HKMetricPrefixMilli molarMass:HKUnitMolarMassBloodGlucose] unitDividedByUnit:[HKUnit literUnit]];
        } else {
            // issue 51
            // @see https://github.com/Telerik-Verified-Plugins/HealthKit/issues/51
            if ([unitString isEqualToString:@"percent"]) {
                unitString = @"%";
            }
            unit = [HKUnit unitFromString:unitString];
        }
    }

    // TODO check that unit is compatible with sampleType if sample type of HKQuantityType
    NSPredicate *predicate1 = [HKQuery predicateForSamplesWithStartDate:startDate endDate:endDate options:HKQueryOptionStrictStartDate];
    NSPredicate *predicate2 = nil;

    BOOL filterOutUserInput = (args[@"filterOutUserInput"] != nil && [args[@"filterOutUserInput"] boolValue]);
    if (filterOutUserInput) {
        predicate2 = [NSPredicate predicateWithFormat:@"metadata.%K != YES", HKMetadataKeyWasUserEntered];
    }

    // only include the user input predicate if it is not nil
    NSArray *predicates = predicate2 != nil ? @[predicate1, predicate2] : @[predicate1];

    NSCompoundPredicate *compoundPredicate = [NSCompoundPredicate andPredicateWithSubpredicates:predicates];

    NSSet *requestTypes = [NSSet setWithObjects:type, nil];
    [[HealthKit sharedHealthStore] requestAuthorizationToShareTypes:nil readTypes:requestTypes completion:^(BOOL success, NSError *error) {
        __block HealthKit *bSelf = self;
        if (success) {
            NSString *endKey = HKSampleSortIdentifierEndDate;
            NSSortDescriptor *endDateSort = [NSSortDescriptor sortDescriptorWithKey:endKey ascending:ascending];
            HKSampleQuery *query = [[HKSampleQuery alloc] initWithSampleType:type
                                                                   predicate:compoundPredicate
                                                                       limit:limit
                                                             sortDescriptors:@[endDateSort]
                                                              resultsHandler:^(HKSampleQuery *sampleQuery,
                                                                      NSArray *results,
                                                                      NSError *innerError) {
                                                                  if (innerError != nil) {
                                                                      dispatch_sync(dispatch_get_main_queue(), ^{
                                                                          [HealthKit triggerErrorCallbackWithMessage:innerError.localizedDescription command:command delegate:bSelf.commandDelegate];
                                                                      });
                                                                  } else {
                                                                      NSMutableArray *finalResults = [[NSMutableArray alloc] initWithCapacity:results.count];

                                                                      for (HKSample *sample in results) {

                                                                          NSDate *startSample = sample.startDate;
                                                                          NSDate *endSample = sample.endDate;
                                                                          NSMutableDictionary *entry = [NSMutableDictionary dictionary];

                                                                          // common indices
                                                                          entry[HKPluginKeyStartDate] =[HealthKit stringFromDate:startSample];
                                                                          entry[HKPluginKeyEndDate] = [HealthKit stringFromDate:endSample];
                                                                          entry[HKPluginKeyUUID] = sample.UUID.UUIDString;

                                                                          //@TODO Update deprecated API calls
                                                                          entry[HKPluginKeySourceName] = sample.source.name;
                                                                          entry[HKPluginKeySourceBundleId] = sample.source.bundleIdentifier;

                                                                          if (sample.metadata == nil || ![NSJSONSerialization isValidJSONObject:sample.metadata]) {
                                                                              entry[HKPluginKeyMetadata] = @{};
                                                                          } else {
                                                                              entry[HKPluginKeyMetadata] = sample.metadata;
                                                                          }

                                                                          // case-specific indices
                                                                          if ([sample isKindOfClass:[HKCategorySample class]]) {

                                                                              HKCategorySample *csample = (HKCategorySample *) sample;
                                                                              entry[HKPluginKeyValue] = @(csample.value);
                                                                              entry[@"categoryType.identifier"] = csample.categoryType.identifier;
                                                                              entry[@"categoryType.description"] = csample.categoryType.description;

                                                                          } else if ([sample isKindOfClass:[HKCorrelationType class]]) {

                                                                              HKCorrelation *correlation = (HKCorrelation *) sample;
                                                                              entry[HKPluginKeyCorrelationType] = correlation.correlationType.identifier;

                                                                          } else if ([sample isKindOfClass:[HKQuantitySample class]]) {

                                                                              HKQuantitySample *qsample = (HKQuantitySample *) sample;
                                                                              [entry setValue:@([qsample.quantity doubleValueForUnit:unit]) forKey:@"quantity"];

                                                                          } else if ([sample isKindOfClass:[HKWorkout class]]) {

                                                                              HKWorkout *wsample = (HKWorkout *) sample;
                                                                              [entry setValue:@(wsample.duration) forKey:@"duration"];

                                                                          }

                                                                          [finalResults addObject:entry];
                                                                      }

                                                                      dispatch_sync(dispatch_get_main_queue(), ^{
                                                                          CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:finalResults];
                                                                          [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
                                                                      });
                                                                  }
                                                              }];

            [[HealthKit sharedHealthStore] executeQuery:query];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                [HealthKit triggerErrorCallbackWithMessage:error.localizedDescription command:command delegate:bSelf.commandDelegate];
            });
        }
    }];
}

/**
 * Query a specified sample type using an aggregation
 *
 * @param command *CDVInvokedUrlCommand
 */
- (void)querySampleTypeAggregated:(CDVInvokedUrlCommand *)command {
    NSDictionary *args = command.arguments[0];
    NSDate *startDate = [NSDate dateWithTimeIntervalSince1970:[args[HKPluginKeyStartDate] longValue]];
    NSDate *endDate = [NSDate dateWithTimeIntervalSince1970:[args[HKPluginKeyEndDate] longValue]];

    NSString *sampleTypeString = args[HKPluginKeySampleType];
    NSString *unitString = args[HKPluginKeyUnit];

    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *interval = [[NSDateComponents alloc] init];

    NSString *aggregation = args[HKPluginKeyAggregation];
    // TODO would be nice to also have the dev pass in the nr of hours/days/..
    if ([@"hour" isEqualToString:aggregation]) {
        interval.hour = 1;
    } else if ([@"week" isEqualToString:aggregation]) {
        interval.day = 7;
    } else if ([@"month" isEqualToString:aggregation]) {
        interval.month = 1;
    } else if ([@"year" isEqualToString:aggregation]) {
        interval.year = 1;
    } else {
        // default 'day'
        interval.day = 1;
    }

    NSDateComponents *anchorComponents = [calendar components:NSCalendarUnitDay | NSCalendarUnitMonth | NSCalendarUnitYear
                                                     fromDate:endDate]; //[NSDate date]];
    anchorComponents.hour = 0; //at 00:00 AM
    NSDate *anchorDate = [calendar dateFromComponents:anchorComponents];
    HKQuantityType *quantityType = [HKObjectType quantityTypeForIdentifier:sampleTypeString];

    HKStatisticsOptions statOpt = HKStatisticsOptionNone;

    if (quantityType == nil) {
        [HealthKit triggerErrorCallbackWithMessage:@"sampleType is invalid" command:command delegate:self.commandDelegate];
        return;
    } else if ([sampleTypeString isEqualToString:@"HKQuantityTypeIdentifierHeartRate"] ||
               [sampleTypeString isEqualToString:@"HKQuantityTypeIdentifierHeartRateVariabilitySDNN"] ||
               [sampleTypeString isEqualToString:@"HKQuantityTypeIdentifierRestingHeartRate"] ||
               [sampleTypeString isEqualToString:@"HKQuantityTypeIdentifierBodyMass"]) {
        statOpt = HKStatisticsOptionDiscreteAverage | HKStatisticsOptionDiscreteMin | HKStatisticsOptionDiscreteMax;
    } else { //HKQuantityTypeIdentifierStepCount, etc...
        statOpt = HKStatisticsOptionCumulativeSum;
    }
    

    HKUnit *unit = nil;
    if (unitString != nil) {
        // issue 51
        // @see https://github.com/Telerik-Verified-Plugins/HealthKit/issues/51
        if ([unitString isEqualToString:@"percent"]) {
            unitString = @"%";
        }
        unit = [HKUnit unitFromString:unitString];
    }

    HKSampleType *type = [HealthKit getHKSampleType:sampleTypeString];
    if (type == nil) {
        [HealthKit triggerErrorCallbackWithMessage:@"sampleType is invalid" command:command delegate:self.commandDelegate];
        return;
    }

    NSPredicate *predicate1 = [HKQuery predicateForSamplesWithStartDate:startDate endDate:endDate options:HKQueryOptionStrictStartDate];
    NSPredicate *predicate2 = nil;

    BOOL filterOutUserInput = (args[@"filterOutUserInput"] != nil && [args[@"filterOutUserInput"] boolValue]);
    if (filterOutUserInput) {
        predicate2 = [NSPredicate predicateWithFormat:@"metadata.%K != YES", HKMetadataKeyWasUserEntered];
    }

    // only include the user input predicate if it is not nil
    NSArray *predicates = predicate2 != nil ? @[predicate1, predicate2] : @[predicate1];

    NSCompoundPredicate *compoundPredicate = [NSCompoundPredicate andPredicateWithSubpredicates:predicates];

    NSSet *requestTypes = [NSSet setWithObjects:type, nil];
    [[HealthKit sharedHealthStore] requestAuthorizationToShareTypes:nil readTypes:requestTypes completion:^(BOOL success, NSError *error) {
        __block HealthKit *bSelf = self;
        if (success) {
            HKStatisticsCollectionQuery *query = [[HKStatisticsCollectionQuery alloc] initWithQuantityType:quantityType
                                                                                   quantitySamplePredicate:compoundPredicate
                                                                                                   options:statOpt
                                                                                                anchorDate:anchorDate
                                                                                        intervalComponents:interval];

            // Set the results handler
            query.initialResultsHandler = ^(HKStatisticsCollectionQuery *statisticsCollectionQuery, HKStatisticsCollection *results, NSError *innerError) {
                if (innerError) {
                    // Perform proper error handling here
                    //                    NSLog(@"*** An error occurred while calculating the statistics: %@ ***",error.localizedDescription);
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        [HealthKit triggerErrorCallbackWithMessage:innerError.localizedDescription command:command delegate:bSelf.commandDelegate];
                    });
                } else {
                    // Get the daily steps over the past n days
                    //            HKUnit *unit = unitString!=nil ? [HKUnit unitFromString:unitString] : [HKUnit countUnit];
                    NSMutableArray *finalResults = [[NSMutableArray alloc] initWithCapacity:[[results statistics] count]];

                    [results enumerateStatisticsFromDate:startDate
                                                  toDate:endDate
                                               withBlock:^(HKStatistics *result, BOOL *stop) {

                                                   NSDate *valueStartDate = result.startDate;
                                                   NSDate *valueEndDate = result.endDate;

                                                   NSMutableDictionary *entry = [NSMutableDictionary dictionary];
                                                   entry[HKPluginKeyStartDate] = [HealthKit stringFromDate:valueStartDate];
                                                   entry[HKPluginKeyEndDate] = [HealthKit stringFromDate:valueEndDate];

                                                   HKQuantity *quantity = nil;
                        if (statOpt == HKStatisticsOptionDiscreteAverage) {
                            quantity = result.averageQuantity;
                            entry[@"quantity"] = @([quantity doubleValueForUnit:unit]);
                        } else if (statOpt == HKStatisticsOptionCumulativeSum) {
                            quantity = result.sumQuantity;
                            entry[@"quantity"] = @([quantity doubleValueForUnit:unit]);
                        } else if (statOpt == HKStatisticsOptionDiscreteMin) {
                            quantity = result.minimumQuantity;
                            entry[@"quantity"] = @([quantity doubleValueForUnit:unit]);
                        } else if (statOpt == HKStatisticsOptionDiscreteMax) {
                            quantity = result.maximumQuantity;
                            entry[@"quantity"] = @([quantity doubleValueForUnit:unit]);
                        } else if (statOpt == (HKStatisticsOptionDiscreteAverage | HKStatisticsOptionDiscreteMin | HKStatisticsOptionDiscreteMax)) {
                            HKQuantity *avg = [result averageQuantity];
                            HKQuantity *min = [result minimumQuantity];
                            HKQuantity *max = [result maximumQuantity];
                            NSMutableDictionary *stats = [NSMutableDictionary dictionary];
                            stats[@"average"] = @([avg doubleValueForUnit:unit]);
                            stats[@"min"] = @([min doubleValueForUnit:unit]);
                            stats[@"max"] = @([max doubleValueForUnit:unit]);
                            
                            entry[@"quantity"] = stats;
                        }

                                                   [finalResults addObject:entry];
                                               }];

                    dispatch_sync(dispatch_get_main_queue(), ^{
                        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:finalResults];
                        [bSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
                    });
                }
            };

            [[HealthKit sharedHealthStore] executeQuery:query];

        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                [HealthKit triggerErrorCallbackWithMessage:error.localizedDescription command:command delegate:bSelf.commandDelegate];
            });
        }
    }];


}

/**
 * Query a specified correlation type
 *
 * @param command *CDVInvokedUrlCommand
 */
- (void)queryCorrelationType:(CDVInvokedUrlCommand *)command {
    NSDictionary *args = command.arguments[0];
    NSDate *startDate = [NSDate dateWithTimeIntervalSince1970:[args[HKPluginKeyStartDate] longValue]];
    NSDate *endDate = [NSDate dateWithTimeIntervalSince1970:[args[HKPluginKeyEndDate] longValue]];
    NSString *correlationTypeString = args[HKPluginKeyCorrelationType];
    NSArray<NSString *> *unitsString = args[HKPluginKeyUnits];

    HKCorrelationType *type = (HKCorrelationType *) [HealthKit getHKSampleType:correlationTypeString];
    if (type == nil) {
        [HealthKit triggerErrorCallbackWithMessage:@"sampleType is invalid" command:command delegate:self.commandDelegate];
        return;
    }
    NSMutableArray *units = [[NSMutableArray alloc] init];
    for (NSString *unitString in unitsString) {
        HKUnit *unit = ((unitString != nil) ? [HKUnit unitFromString:unitString] : nil);
        [units addObject:unit];
    }

    // TODO check that unit is compatible with sampleType if sample type of HKQuantityType
    NSPredicate *predicate = [HKQuery predicateForSamplesWithStartDate:startDate endDate:endDate options:HKQueryOptionStrictStartDate];

    HKCorrelationQuery *query = [[HKCorrelationQuery alloc] initWithType:type predicate:predicate samplePredicates:nil completion:^(HKCorrelationQuery *correlationQuery, NSArray *correlations, NSError *error) {
        __block HealthKit *bSelf = self;
        if (error) {
            dispatch_sync(dispatch_get_main_queue(), ^{
                [HealthKit triggerErrorCallbackWithMessage:error.localizedDescription command:command delegate:bSelf.commandDelegate];
            });
        } else {
            NSMutableArray *finalResults = [[NSMutableArray alloc] initWithCapacity:correlations.count];
            for (HKSample *sample in correlations) {
                NSDate *startSample = sample.startDate;
                NSDate *endSample = sample.endDate;

                NSMutableDictionary *entry = [NSMutableDictionary dictionary];
                entry[HKPluginKeyStartDate] = [HealthKit stringFromDate:startSample];
                entry[HKPluginKeyEndDate] = [HealthKit stringFromDate:endSample];

                // common indices
                entry[HKPluginKeyUUID] = sample.UUID.UUIDString;
                entry[HKPluginKeySourceName] = sample.source.name;
                entry[HKPluginKeySourceBundleId] = sample.source.bundleIdentifier;
                if (sample.metadata == nil || ![NSJSONSerialization isValidJSONObject:sample.metadata]) {
                    entry[HKPluginKeyMetadata] = @{};
                } else {
                    entry[HKPluginKeyMetadata] = sample.metadata;
                }


                if ([sample isKindOfClass:[HKCategorySample class]]) {

                    HKCategorySample *csample = (HKCategorySample *) sample;
                    entry[HKPluginKeyValue] = @(csample.value);
                    entry[@"categoryType.identifier"] = csample.categoryType.identifier;
                    entry[@"categoryType.description"] = csample.categoryType.description;

                } else if ([sample isKindOfClass:[HKCorrelation class]]) {

                    HKCorrelation *correlation = (HKCorrelation *) sample;
                    entry[HKPluginKeyCorrelationType] = correlation.correlationType.identifier;

                    NSMutableArray *samples = [NSMutableArray arrayWithCapacity:correlation.objects.count];
                    for (HKQuantitySample *quantitySample in correlation.objects) {
                        for (int i=0; i<[units count]; i++) {
                            HKUnit *unit = units[i];
                            NSString *unitS = unitsString[i];
                            if ([quantitySample.quantity isCompatibleWithUnit:unit]) {
                                [samples addObject:@{
                                                     HKPluginKeyStartDate: [HealthKit stringFromDate:quantitySample.startDate],
                                                     HKPluginKeyEndDate: [HealthKit stringFromDate:quantitySample.endDate],
                                                     HKPluginKeySampleType: quantitySample.sampleType.identifier,
                                                     HKPluginKeyValue: @([quantitySample.quantity doubleValueForUnit:unit]),
                                                     HKPluginKeyUnit: unitS,
                                                     HKPluginKeyMetadata: (quantitySample.metadata == nil || ![NSJSONSerialization isValidJSONObject:quantitySample.metadata]) ? @{} : quantitySample.metadata,
                                                     HKPluginKeyUUID: quantitySample.UUID.UUIDString
                                                     }
                                 ];
                                break;
                            }
                        }
                    }
                    entry[HKPluginKeyObjects] = samples;

                } else if ([sample isKindOfClass:[HKQuantitySample class]]) {

                    HKQuantitySample *qsample = (HKQuantitySample *) sample;
                    for (int i=0; i<[units count]; i++) {
                        HKUnit *unit = units[i];
                        if ([qsample.quantity isCompatibleWithUnit:unit]) {
                            double quantity = [qsample.quantity doubleValueForUnit:unit];
                            entry[@"quantity"] = [NSString stringWithFormat:@"%f", quantity];
                            break;
                        }
                    }

                } else if ([sample isKindOfClass:[HKWorkout class]]) {

                    HKWorkout *wsample = (HKWorkout *) sample;
                    entry[@"duration"] = @(wsample.duration);

                } else if ([sample isKindOfClass:[HKCorrelationType class]]) {
                    // TODO
                    // wat do?
                }

                [finalResults addObject:entry];
            }

            dispatch_sync(dispatch_get_main_queue(), ^{
                CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:finalResults];
                [bSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            });
        }
    }];
    [[HealthKit sharedHealthStore] executeQuery:query];
}

/**
 * Save sample data
 *
 * @param command *CDVInvokedUrlCommand
 */
- (void)saveSample:(CDVInvokedUrlCommand *)command {
    NSDictionary *args = command.arguments[0];

    //Use helper method to create quantity sample
    NSError *error = nil;
    HKSample *sample = [self loadHKSampleFromInputDictionary:args error:&error];

    //If error in creation, return plugin result
    if (error) {
        [HealthKit triggerErrorCallbackWithMessage:error.localizedDescription command:command delegate:self.commandDelegate];
        return;
    }

    //Otherwise save to health store
    [[HealthKit sharedHealthStore] saveObject:sample withCompletion:^(BOOL success, NSError *innerError) {
        __block HealthKit *bSelf = self;
        if (success) {
            dispatch_sync(dispatch_get_main_queue(), ^{
                CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
                [bSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            });
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                [HealthKit triggerErrorCallbackWithMessage:innerError.localizedDescription command:command delegate:bSelf.commandDelegate];
            });
        }
    }];

}

/**
 * Save correlation data
 *
 * @param command *CDVInvokedUrlCommand
 */
- (void)saveCorrelation:(CDVInvokedUrlCommand *)command {
    NSDictionary *args = command.arguments[0];
    NSError *error = nil;

    //Use helper method to create correlation
    HKCorrelation *correlation = [self loadHKCorrelationFromInputDictionary:args error:&error];

    //If error in creation, return plugin result
    if (error) {
        [HealthKit triggerErrorCallbackWithMessage:error.localizedDescription command:command delegate:self.commandDelegate];
        return;
    }

    //Otherwise save to health store
    [[HealthKit sharedHealthStore] saveObject:correlation withCompletion:^(BOOL success, NSError *saveError) {
        __block HealthKit *bSelf = self;
        if (success) {
            dispatch_sync(dispatch_get_main_queue(), ^{
                CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
                [bSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            });
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                [HealthKit triggerErrorCallbackWithMessage:saveError.localizedDescription command:command delegate:bSelf.commandDelegate];
            });
        }
    }];
}

/**
 * Delete matching samples from the HealthKit store.
 * TODO: consider adding deletion by ID, this will likely require a query, to retrieve the object, and the a deletion
 * for querying, we may need to run: https://developer.apple.com/documentation/healthkit/hkquery/1614783-predicateforobjectwithuuid?language=objc
 * for deleting, we may need to use: https://developer.apple.com/documentation/healthkit/hkhealthstore/1614155-deleteobject
 *
 * @param command *CDVInvokedUrlCommand
 */
- (void)deleteSamples:(CDVInvokedUrlCommand *)command {
  NSDictionary *args = command.arguments[0];
  NSDate *startDate = [NSDate dateWithTimeIntervalSince1970:[args[HKPluginKeyStartDate] longValue]];
  NSDate *endDate = [NSDate dateWithTimeIntervalSince1970:[args[HKPluginKeyEndDate] longValue]];
  NSString *sampleTypeString = args[HKPluginKeySampleType];

  HKSampleType *type = [HealthKit getHKSampleType:sampleTypeString];
  if (type == nil) {
    [HealthKit triggerErrorCallbackWithMessage:@"sampleType is invalid" command:command delegate:self.commandDelegate];
    return;
  }

  NSPredicate *predicate = [HKQuery predicateForSamplesWithStartDate:startDate endDate:endDate options:HKQueryOptionStrictStartDate];

  NSSet *requestTypes = [NSSet setWithObjects:type, nil];
  [[HealthKit sharedHealthStore] requestAuthorizationToShareTypes:nil readTypes:requestTypes completion:^(BOOL success, NSError *error) {
    __block HealthKit *bSelf = self;
    if (success) {
      [[HealthKit sharedHealthStore] deleteObjectsOfType:type predicate:predicate withCompletion:^(BOOL success, NSUInteger deletedObjectCount, NSError * _Nullable deletionError) {
        if (deletionError != nil) {
          dispatch_sync(dispatch_get_main_queue(), ^{
            [HealthKit triggerErrorCallbackWithMessage:deletionError.localizedDescription command:command delegate:bSelf.commandDelegate];
          });
        } else {
          dispatch_sync(dispatch_get_main_queue(), ^{
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:(int)deletedObjectCount];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
          });
        }
      }];
    }
  }];
}



- (void)queryWorkoutRoutes:(CDVInvokedUrlCommand*)command {
    NSString *workoutUUID = [command.arguments objectAtIndex:0];

    // Fetch the workout from HealthKit using the UUID
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:workoutUUID];
    NSPredicate *predicate = [HKQuery predicateForObjectWithUUID:uuid];

    HKSampleQuery *workoutQuery = [[HKSampleQuery alloc] initWithSampleType:[HKObjectType workoutType] predicate:predicate limit:1 sortDescriptors:nil resultsHandler:^(HKSampleQuery *query, NSArray *results, NSError *error) {
        if (!results || error || results.count == 0) {
            CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Workout not found or error occurred."];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
            return;
        }

        HKWorkout *workout = (HKWorkout*)[results firstObject];
        [self fetchAllRoutesForWorkout:workout withCommand:command];
    }];

    [[HealthKit sharedHealthStore] executeQuery:workoutQuery];
}

- (void)fetchAllRoutesForWorkout:(HKWorkout*)workout withCommand:(CDVInvokedUrlCommand*)command {
    NSMutableArray *locationsArray = [NSMutableArray array];
    NSPredicate *predicate = [HKQuery predicateForObjectsFromWorkout:workout];
    HKSampleType *routeType = [HKSeriesType workoutRouteType];
    
    HKSampleQuery *routeQuery = [[HKSampleQuery alloc] initWithSampleType:routeType predicate:predicate limit:HKObjectQueryNoLimit sortDescriptors:nil resultsHandler:^(HKSampleQuery *query, NSArray *results, NSError *error) {
        if (error || results.count == 0) {
            CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"No routes found or error occurred."];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
            return;
        }

        __block NSUInteger remainingRoutes = results.count;
        __block BOOL hasErrorOccurred = NO;

        for (HKWorkoutRoute *route in results) {
            [self fetchLocationDataForRoute:route withLocationsArray:locationsArray completion:^(BOOL success, NSError *error) {
                if (!success || error) {
                    hasErrorOccurred = YES;
                    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Error fetching route data."];
                    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
                    return;
                }

                remainingRoutes--;

                // Check if all routes have been processed
                if (remainingRoutes == 0 && !hasErrorOccurred) {
                    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:locationsArray];
                    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
                }
            }];
        }
    }];

    [[HealthKit sharedHealthStore] executeQuery:routeQuery];
}

- (void)fetchLocationDataForRoute:(HKWorkoutRoute*)route withLocationsArray:(NSMutableArray*)locationsArray completion:(void (^)(BOOL success, NSError *error))completion {
    __block BOOL hasErrorOccurred = NO;

    HKWorkoutRouteQuery *query = [[HKWorkoutRouteQuery alloc] initWithRoute:route dataHandler:^(HKWorkoutRouteQuery *query, NSArray<CLLocation *> *locations, BOOL done, NSError *error) {
        if (error) {
            hasErrorOccurred = YES;
            completion(NO, error);
            return;
        }

        for (CLLocation *location in locations) {
            NSDictionary *locationDict = @{
                @"lat": @(location.coordinate.latitude),
                @"lng": @(location.coordinate.longitude),
                @"alt": @(location.altitude),
                @"timestamp": @([location.timestamp timeIntervalSince1970] * 1000)  // Convert to milliseconds
            };
            [locationsArray addObject:locationDict];
        }

        // Check if this is the final batch of locations for this route
        if (done && !hasErrorOccurred) {
            completion(YES, nil);  // Indicate success after all locations are fetched
        }
    }];

    [[HealthKit sharedHealthStore] executeQuery:query];
}

- (void)queryHeartRateDuringWorkout:(CDVInvokedUrlCommand*)command {
    NSString *workoutUUID = [command.arguments objectAtIndex:0];

    // Fetch the workout from HealthKit using the UUID
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:workoutUUID];
    NSPredicate *predicate = [HKQuery predicateForObjectWithUUID:uuid];

    HKSampleQuery *workoutQuery = [[HKSampleQuery alloc] initWithSampleType:[HKObjectType workoutType] predicate:predicate limit:1 sortDescriptors:nil resultsHandler:^(HKSampleQuery *query, NSArray *results, NSError *error) {
        if (!results || error || results.count == 0) {
            CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Workout not found or error occurred."];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
            return;
        }

        HKWorkout *workout = (HKWorkout*)[results firstObject];
        [self fetchHeartRateForWorkout:workout withCommand:command];
    }];

    [[HealthKit sharedHealthStore] executeQuery:workoutQuery];
}

- (void)fetchHeartRateForWorkout:(HKWorkout*)workout withCommand:(CDVInvokedUrlCommand*)command {
    HKQuantityType *heartRateType = [HKObjectType quantityTypeForIdentifier:HKQuantityTypeIdentifierHeartRate];

    // Create a predicate to fetch heart rate samples during the workout period
    NSPredicate *predicate = [HKQuery predicateForSamplesWithStartDate:workout.startDate endDate:workout.endDate options:HKQueryOptionStrictStartDate];

    HKSampleQuery *heartRateQuery = [[HKSampleQuery alloc] initWithSampleType:heartRateType predicate:predicate limit:HKObjectQueryNoLimit sortDescriptors:nil resultsHandler:^(HKSampleQuery *query, NSArray *results, NSError *error) {
        if (error) {
            CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Error fetching heart rate data."];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
            return;
        }

        NSMutableArray *heartRateArray = [NSMutableArray array];
        for (HKQuantitySample *sample in results) {
            double heartRate = [sample.quantity doubleValueForUnit:[HKUnit unitFromString:@"count/min"]];
            NSDate *timestamp = sample.startDate;
            NSDictionary *heartRateDict = @{
                @"bpm": @(heartRate),
                @"timestamp": @([timestamp timeIntervalSince1970] * 1000)  // Convert to milliseconds since epoch
            };
            [heartRateArray addObject:heartRateDict];
        }

        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:heartRateArray];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    }];

    [[HealthKit sharedHealthStore] executeQuery:heartRateQuery];
}

@end

#pragma clang diagnostic pop
