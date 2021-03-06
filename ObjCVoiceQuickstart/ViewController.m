//
//  ViewController.m
//  Twilio Voice Quickstart - Objective-C
//
//  Copyright © 2016 Twilio, Inc. All rights reserved.
//

#import "ViewController.h"

@import AVFoundation;
@import PushKit;
@import TwilioVoiceClient;

static NSString *const kYourServerBaseURLString = <#URL TO YOUR ACCESS TOKEN SERVER#>;
static NSString *const kAccessTokenEndpoint = @"/accessToken";

@interface ViewController () <PKPushRegistryDelegate, TVONotificationDelegate, TVOIncomingCallDelegate, TVOOutgoingCallDelegate, AVAudioPlayerDelegate>
@property (nonatomic, strong) NSString *deviceTokenString;

@property (nonatomic, strong) PKPushRegistry *voipRegistry;
@property (nonatomic, strong) TVOIncomingCall *incomingCall;
@property (nonatomic, strong) TVOOutgoingCall *outgoingCall;

@property (nonatomic, weak) IBOutlet UIImageView *iconView;
@property (nonatomic, assign, getter=isSpinning) BOOL spinning;

@property (nonatomic, weak) IBOutlet UIButton *placeCallButton;
@property (nonatomic, strong) UIAlertController* incomingAlertController;

@property (nonatomic, strong) AVAudioPlayer *ringtonePlayer;
typedef void (^RingtonePlaybackCallback)(void);
@property (nonatomic, strong) RingtonePlaybackCallback ringtonePlaybackCallback;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.voipRegistry = [[PKPushRegistry alloc] initWithQueue:dispatch_get_main_queue()];
    self.voipRegistry.delegate = self;
    self.voipRegistry.desiredPushTypes = [NSSet setWithObject:PKPushTypeVoIP];

    [self toggleUIState:YES];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
}

- (NSString *)fetchAccessToken {
    NSString *accessTokenURLString = [kYourServerBaseURLString stringByAppendingString:kAccessTokenEndpoint];

    NSString *accessToken = [NSString stringWithContentsOfURL:[NSURL URLWithString:accessTokenURLString]
                                                     encoding:NSUTF8StringEncoding
                                                        error:nil];
    return accessToken;
}

- (IBAction)placeCall:(id)sender {
    __weak typeof(self) weakSelf = self;
    [self playOutgoingRingtone:^{
        __strong typeof(self) strongSelf = weakSelf;
        strongSelf.outgoingCall = [[VoiceClient sharedInstance] call:[strongSelf fetchAccessToken]
                                                              params:@{}
                                                            delegate:strongSelf];
    
        if (!strongSelf.outgoingCall) {
            NSLog(@"Failed to start outgoing call");
            return;
        }
    }];

    [self toggleUIState:NO];
    [self startSpin];
}

- (void)toggleUIState:(BOOL)isEnabled {
    self.placeCallButton.enabled = isEnabled;
}

#pragma mark - PKPushRegistryDelegate
- (void)pushRegistry:(PKPushRegistry *)registry didUpdatePushCredentials:(PKPushCredentials *)credentials forType:(NSString *)type {
    NSLog(@"pushRegistry:didUpdatePushCredentials:forType:");

    if ([type isEqualToString:PKPushTypeVoIP]) {
        self.deviceTokenString = [credentials.token description];
        NSString *accessToken = [self fetchAccessToken];

        [[VoiceClient sharedInstance] registerWithAccessToken:accessToken
                                                  deviceToken:self.deviceTokenString
                                                   completion:^(NSError *error) {
             if (error) {
                 NSLog(@"An error occurred while registering: %@", [error localizedDescription]);
             }
             else {
                 NSLog(@"Successfully registered for VoIP push notifications.");
             }
         }];
    }
}

- (void)pushRegistry:(PKPushRegistry *)registry didInvalidatePushTokenForType:(PKPushType)type {
    NSLog(@"pushRegistry:didInvalidatePushTokenForType:");

    if ([type isEqualToString:PKPushTypeVoIP]) {
        NSString *accessToken = [self fetchAccessToken];

        [[VoiceClient sharedInstance] unregisterWithAccessToken:accessToken
                                                    deviceToken:self.deviceTokenString
                                                     completion:^(NSError * _Nullable error) {
            if (error) {
                NSLog(@"An error occurred while unregistering: %@", [error localizedDescription]);
            }
            else {
                NSLog(@"Successfully unregistered for VoIP push notifications.");
            }
        }];

        self.deviceTokenString = nil;
    }
}

- (void)pushRegistry:(PKPushRegistry *)registry didReceiveIncomingPushWithPayload:(PKPushPayload *)payload forType:(NSString *)type {
    NSLog(@"pushRegistry:didReceiveIncomingPushWithPayload:forType:");
    if ([type isEqualToString:PKPushTypeVoIP]) {
        [[VoiceClient sharedInstance] handleNotification:payload.dictionaryPayload
                                                delegate:self];
    }
}

#pragma mark - TVONotificationDelegate
- (void)incomingCallReceived:(TVOIncomingCall *)incomingCall {
    NSLog(@"incomingCallReceived:");
    
    if (self.incomingCall || self.outgoingCall) {
        NSLog(@"Already an active call. Ignoring incoming call from %@", incomingCall.from);
        return;
    }
    
    self.incomingCall = incomingCall;
    self.incomingCall.delegate = self;

    NSString *from = incomingCall.from;
    NSString *alertMessage = [NSString stringWithFormat:@"From %@", from];
    
    [self playIncomingRingtone];

    self.incomingAlertController = [UIAlertController alertControllerWithTitle:@"Incoming" message:alertMessage preferredStyle:UIAlertControllerStyleAlert];

    typeof(self) __weak weakSelf = self;

    UIAlertAction *reject = [UIAlertAction actionWithTitle:@"Reject" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self stopIncomingRingtone:^{
            [incomingCall reject];
        }];

        typeof(self) __strong strongSelf = weakSelf;
        strongSelf.incomingAlertController = nil;
        [strongSelf toggleUIState:YES];
    }];
    [self.incomingAlertController addAction:reject];

    UIAlertAction *ignore = [UIAlertAction actionWithTitle:@"Ignore" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [incomingCall ignore];
        
        [self stopIncomingRingtone:nil];

        typeof(self) __strong strongSelf = weakSelf;
        strongSelf.incomingAlertController = nil;
        [strongSelf toggleUIState:YES];
    }];
    [self.incomingAlertController addAction:ignore];

    UIAlertAction *accept = [UIAlertAction actionWithTitle:@"Accept" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        typeof(self) __strong strongSelf = weakSelf;
        [self stopIncomingRingtone:^{
            [incomingCall acceptWithDelegate:strongSelf];
        }];

        strongSelf.incomingAlertController = nil;
        [strongSelf startSpin];
    }];
    [self.incomingAlertController addAction:accept];

    [self toggleUIState:NO];
    [self presentViewController:self.incomingAlertController animated:YES completion:nil];

    // If the application is not in the foreground, post a local notification
    if ([[UIApplication sharedApplication] applicationState] != UIApplicationStateActive) {
        UIApplication* app = [UIApplication sharedApplication];
        UILocalNotification* notification = [[UILocalNotification alloc] init];
        notification.alertBody = [NSString stringWithFormat:@"Incoming Call from %@", incomingCall.from];

        [app presentLocalNotificationNow:notification];
    }
}

- (void)incomingCallCancelled:(TVOIncomingCall *)incomingCall {
    NSLog(@"incomingCallCancelled:");
    
    if (![incomingCall.callSid isEqualToString:self.incomingCall.callSid]) {
        NSLog(@"Incoming (but not current) call from \"%@\" cancelled. Just ignore it.", incomingCall.from);
        return;
    }
    
    [self stopIncomingRingtone:nil];
    [self playDisconnectSound];

    if (self.incomingAlertController) {
        typeof(self) __weak weakSelf = self;

        [self dismissViewControllerAnimated:YES completion:^{
            typeof(self) __strong strongSelf = weakSelf;
            strongSelf.incomingAlertController = nil;
            [strongSelf toggleUIState:YES];
        }];
    }
    
    self.incomingCall = nil;

    [[UIApplication sharedApplication] cancelAllLocalNotifications];
}

- (void)notificationError:(NSError *)error {
    NSLog(@"notificationError: %@", [error localizedDescription]);
}

#pragma mark - TVOIncomingCallDelegate
- (void)incomingCallDidConnect:(TVOIncomingCall *)incomingCall {
    NSLog(@"incomingCallDidConnect:");

    self.incomingCall = incomingCall;
    [self toggleUIState:NO];
    [self stopSpin];
    [self routeAudioToSpeaker];
}

- (void)incomingCallDidDisconnect:(TVOIncomingCall *)incomingCall {
    NSLog(@"incomingCallDidDisconnect:");
    
    [self playDisconnectSound];

    self.incomingCall = nil;
    [self toggleUIState:YES];
}

- (void)incomingCall:(TVOIncomingCall *)incomingCall didFailWithError:(NSError *)error {
    NSLog(@"incomingCall:didFailWithError: %@", [error localizedDescription]);

    self.incomingCall = nil;
    [self toggleUIState:YES];
    [self stopSpin];
}

#pragma mark - TVOOutgoingCallDelegate
- (void)outgoingCallDidConnect:(TVOOutgoingCall *)outgoingCall {
    NSLog(@"outgoingCallDidConnect:");
    
    self.outgoingCall = outgoingCall;

    [self toggleUIState:NO];
    [self stopSpin];
    [self routeAudioToSpeaker];
}

- (void)outgoingCallDidDisconnect:(TVOOutgoingCall *)outgoingCall {
    NSLog(@"outgoingCallDidDisconnect:");
    
    [self playDisconnectSound];

    self.outgoingCall = nil;
    [self toggleUIState:YES];
}

- (void)outgoingCall:(TVOOutgoingCall *)outgoingCall didFailWithError:(NSError *)error {
    NSLog(@"outgoingCall:didFailWithError: %@", [error localizedDescription]);

    self.outgoingCall = nil;
    [self toggleUIState:YES];
    [self stopSpin];
}

#pragma mark - AVAudioSession
- (void)routeAudioToSpeaker {
    NSError * error;
    if (![[AVAudioSession sharedInstance] overrideOutputAudioPort:kAudioSessionOverrideAudioRoute_Speaker
                                                            error:&error]) {
        NSLog(@"Failed to route audio to speaker: %@", [error localizedDescription]);
    }
}

#pragma mark - Ringtone player & AVAudioPlayerDelegate
- (void)playOutgoingRingtone:(RingtonePlaybackCallback)completion {
    self.ringtonePlaybackCallback = completion;
    
    NSString *ringtonePath = [[NSBundle mainBundle] pathForResource:@"outgoing" ofType:@"wav"];
    if ([ringtonePath length] <= 0) {
        NSLog(@"Can't find outgoing sound file");
        if (self.ringtonePlaybackCallback) {
            self.ringtonePlaybackCallback();
        }
        return;
    }
    
    self.ringtonePlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL URLWithString:ringtonePath] error:nil];
    self.ringtonePlayer.delegate = self;
    
    [self playRingtone];
}

- (void)playIncomingRingtone {
    NSString *ringtonePath = [[NSBundle mainBundle] pathForResource:@"incoming" ofType:@"wav"];
    if ([ringtonePath length] <= 0) {
        NSLog(@"Can't find incoming sound file");
        return;
    }
    
    self.ringtonePlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL URLWithString:ringtonePath] error:nil];
    self.ringtonePlayer.delegate = self;
    self.ringtonePlayer.numberOfLoops = -1;
    
    [self playRingtone];
}

- (void)stopIncomingRingtone:(RingtonePlaybackCallback)completion {
    if (!self.ringtonePlayer.isPlaying) {
        if (completion) {
            completion();
        }
        return;
    }
    
    self.ringtonePlayer.delegate = self;
    self.ringtonePlaybackCallback = completion;
    self.ringtonePlayer.numberOfLoops = 1;
}

- (void)playDisconnectSound {
    NSString *ringtonePath = [[NSBundle mainBundle] pathForResource:@"disconnect" ofType:@"wav"];
    if ([ringtonePath length] <= 0) {
        NSLog(@"Can't find disconnect sound file");
        return;
    }
    
    self.ringtonePlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL URLWithString:ringtonePath] error:nil];
    self.ringtonePlayer.delegate = self;
    self.ringtonePlaybackCallback = nil;
    
    [self playRingtone];
}

- (void)playRingtone {
    NSError *error = nil;
    if (![[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                                error:&error]) {
        NSLog(@"Unable to reroute audio: %@", [error localizedDescription]);
    }
    
    [self routeAudioToSpeaker];
    
    self.ringtonePlayer.volume = 1.0f;
    [self.ringtonePlayer play];
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    if (self.ringtonePlaybackCallback) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) strongSelf = weakSelf;
            strongSelf.ringtonePlaybackCallback();
        });
        
        NSError *error = nil;
        if (![[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayAndRecord
                                                    error:&error]) {
            NSLog(@"Unable to reroute audio: %@", [error localizedDescription]);
        }
    }
}

#pragma mark - Icon spinning
- (void)startSpin {
    if (!self.isSpinning) {
        self.spinning = YES;
        [self spinWithOptions:UIViewAnimationOptionCurveEaseIn];
    }
}

- (void)stopSpin {
    self.spinning = NO;
}

- (void)spinWithOptions:(UIViewAnimationOptions)options {
    typeof(self) __weak weakSelf = self;

    [UIView animateWithDuration:0.5f
                          delay:0.0f
                        options:options
                     animations:^{
                         typeof(self) __strong strongSelf = weakSelf;
                         strongSelf.iconView.transform = CGAffineTransformRotate(strongSelf.iconView.transform, M_PI / 2);
                     }
                     completion:^(BOOL finished) {
                         typeof(self) __strong strongSelf = weakSelf;
                         if (finished) {
                             if (strongSelf.isSpinning) {
                                 [strongSelf spinWithOptions:UIViewAnimationOptionCurveLinear];
                             } else if (options != UIViewAnimationOptionCurveEaseOut) {
                                 [strongSelf spinWithOptions:UIViewAnimationOptionCurveEaseOut];
                             }
                         }
                     }];
}


@end
