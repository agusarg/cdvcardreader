//
//  CDVCardReader.m
//  cashmobile
//
//  Created by Agustin Andreucci on 2/2/14.
//
//

#import "CDVCardReader.h"

@implementation CDVCardReader

int FREQ = 22050;

#define kOutputBus 0
#define kInputBus 1

AudioComponentInstance audioUnit;

int QUORUM = 5; //Sample count of either silence or 'noise' to start or stop recording.
long RECORDING_BUFFER_SIZE; //Buffer size of the buffer used to hold recorded samples.
short SILENCE_THRESHOLD = 300; //Below this value we consider silent input.
BOOL recording = false; //Whether we are recording or not.
int silentSamplesCount = 0;
int loudSamplesCount = 0;
long recordedSamplesCount = 0;
short *recordingBuffer = NULL;

#define STATUS_READY 0
#define STATUS_RECORDING 1
#define STATUS_DATA_PRESENT 2

int recordingStatus = STATUS_READY;

pthread_mutex_t mutex;

void setRecordingStatus(int value) {
    recordingStatus = value;
}

int getRecordingStatus() {
    return recordingStatus;
}

void checkStatus(OSStatus status, NSString *op)
{
    if (status < 0) {
        NSError *error = [NSError errorWithDomain: NSOSStatusErrorDomain code: status userInfo: nil];
        NSLog(@"%s ->error: %s", [op cStringUsingEncoding:[NSString defaultCStringEncoding]], [[error description] cStringUsingEncoding:[NSString defaultCStringEncoding]]);
    }
}

bool is1(int samples, int baseSampleCount) {
    return (abs(samples - baseSampleCount) <= abs(samples - baseSampleCount*2));
}

bool changes(int i, short minThreshold) {
    bool b = (recordingBuffer[i] > minThreshold && recordingBuffer[i+1] < -minThreshold) || (recordingBuffer[i] < -minThreshold && recordingBuffer[i+1] > minThreshold);
    
    return b;
}

//Centers samples around 0
void recenterBuffer(short*dataBuffer, long size) {
    int i = 0;
    int sum = 0;
    
    short lastVal = dataBuffer[0];
    
    for (i = 0; i < size; i++) {
        sum += dataBuffer[i];
    }
    
    short avg = sum / size;
    for (i = 0; i < size; i++) {
        dataBuffer[i] -= avg;
        //dataBuffer[i] = lastVal*0.2 + (dataBuffer[i]*(0.8));
        //dataBuffer[i] = dataBuffer[i] * 1.5;
    }
    
    NSLog(@"Recentered buffer avg: %i", avg);
}

short getMinLevel(short *dataBuffer, long size) {
    int i = 0;
    short value;
    int sum = 0;
    short max = 0;
    int zc = 0;
    
    bool b = false;
    for (i = 0; i < size - 1; i++) {
        value = abs(dataBuffer[i]);
        if (value > max && value > SILENCE_THRESHOLD) {
            max = value;
            //NSLog(@"max: %i", max);
            b = true;
        }
        
        if (changes(i, 0) && b) {
            sum += max;
            zc++;
            max = 0;
            b = false;
        }
    }
    if (zc > 0)
        return (sum / zc) * 0.1;
    else
        return SILENCE_THRESHOLD;
}

int getPeaks(short *dataBuffer, long size, short minLevel, short **res) {
    short *peaks = malloc(sizeof(short) * size);
    int peakCount = 0;
    short lastPeak = dataBuffer[0];
    int i;
    
    for (i = 1; i < size - 1; i++) {
        if (abs(dataBuffer[i]) > minLevel) {
            if ((dataBuffer[i] > 0) && (dataBuffer[i-1] <= dataBuffer[i]) && (dataBuffer[i] >= dataBuffer[i+1]))
            {
                lastPeak = peaks[peakCount];
                peaks[peakCount] = dataBuffer[i];
                peakCount++;
            } else if ((dataBuffer[i] < 0) &&
                       (dataBuffer[i-1] >= dataBuffer[i])
                       && (dataBuffer[i] <=  dataBuffer[i+1]))
            {
                lastPeak = peaks[peakCount];
                peaks[peakCount] = dataBuffer[i];
                peakCount++;
            } else {
                peaks[i] = lastPeak;
            }
        } else {
            peaks[i] = lastPeak;
        }
    }
    
    *res = peaks;
    return size;
}

int decodeRawDataToBitSetPeakMethod(short *dataBuffer, long size, unsigned short **res, short minLevel) {
    int basePeakCount = 0;
    int i = 0;
    int peakFlipsToIgnore = 3;
    int peakFlipsIgnored = 0;
    int bitCount = 0;
    
    NSLog(@"Now try with peak scan method.");
    
    unsigned short *bitBuffer = malloc(sizeof(unsigned short) * 1000);
    
    short *peaks;
    int peakCount = getPeaks(dataBuffer, size, minLevel, &peaks);
    NSLog(@"peakCount: %i", peakCount);
    bool bitForFreq = false;
    bool expecting1SecondHalf = false;
    int psign = -1;
    //Stablish base frequency
    bool b = true;
    int lastFlipPeakIndex = 0;

    while (i < peakCount && b) {
        if (peaks[i] * psign < 0) {
            psign *= -1;
            if (peakFlipsIgnored < peakFlipsToIgnore) {
                peakFlipsIgnored++;
            } else if (basePeakCount < 1) {
                basePeakCount = (i - lastFlipPeakIndex) / 2;
            } else {
                bitForFreq = is1((i - lastFlipPeakIndex), basePeakCount);
                if (bitForFreq) {
                    basePeakCount = ((i - lastFlipPeakIndex) + basePeakCount) / 2;
                    if (expecting1SecondHalf) {
                        //NSLog(@"Base sample count: %i", basePeakCount);
                        bitBuffer[bitCount] = 1;
                        bitCount++;
                        expecting1SecondHalf = false;
                    } else {
                        expecting1SecondHalf = true;
                    }
                } else {
                    basePeakCount = ((i - lastFlipPeakIndex) / 2 + basePeakCount) / 2;
                    if (expecting1SecondHalf) {
                        NSLog(@"Error! second 1bit half was expected!");
                        b = false;
                    } else {
                        //NSLog(@"Base sample count: %i", basePeakCount);
                        bitBuffer[bitCount] = 0;
                        bitCount++;
                    }
                }
            }
            lastFlipPeakIndex = i;
        } else {

        }
        i++;
    }
    
    free(peaks);
    
    NSMutableString *rawBinary = [[NSMutableString alloc] initWithString:@"raw binary peak method: "];
    
    if (bitCount > 0 && b) {
        *res = malloc(sizeof(unsigned short) * bitCount);
        
        memcpy(*res, bitBuffer, bitCount * sizeof(unsigned short));
        
        unsigned short *test = *res;
        for (i = 0; i < bitCount; i++) {
            if (test[i] == 1)
                [rawBinary appendString: @"1"];
            else
                [rawBinary appendString: @"0"];
        }
        
        NSLog(rawBinary);
        NSLog(@"Bit count: %i", bitCount);
    } else {
        *res = NULL;
    }
    
    
    free(bitBuffer);
    
    return bitCount;
}

int decodeRawDataToBitSet(short *dataBuffer, long size, unsigned short **res, short minLevel)
{
    int baseSampleCount = 0;
    int samplesSinceZeroCrossing = 0;
    int i = 0;
    int zeroCrossingsToIgnore = 1;
    int ignoredZeroCrossings = 0;
    int bitCount = 0;
    
    recenterBuffer(dataBuffer, size);
    
    NSLog(@"minLevel: %i", minLevel);
    
    unsigned short *bitBuffer = malloc(sizeof(unsigned short) * 1000);
    
    bool bitForFreq = false;
    bool expecting1SecondHalf = false;
    int psign = -1;
    //Stablish base frequency
    bool b = true;
    while (i < size && b) {
        if (dataBuffer[i] * psign < 0 && abs(dataBuffer[i]) > minLevel) {
            psign *= -1;
            if (ignoredZeroCrossings < zeroCrossingsToIgnore) {
                ignoredZeroCrossings++;
            } else if (baseSampleCount < 1) {
                baseSampleCount = samplesSinceZeroCrossing / 2;
            } else {
                bitForFreq = is1(samplesSinceZeroCrossing, baseSampleCount);
                if (bitForFreq) {
                    baseSampleCount = samplesSinceZeroCrossing;
                    if (expecting1SecondHalf) {
                        //NSLog(@"Base sample count: %i", baseSampleCount);
                        bitBuffer[bitCount] = 1;
                        bitCount++;
                        expecting1SecondHalf = false;
                    } else {
                        expecting1SecondHalf = true;
                    }
                } else {
                    baseSampleCount = samplesSinceZeroCrossing / 2;
                    if (expecting1SecondHalf) {
                        NSLog(@"Error! second 1bit half was expected! bits: %i", bitCount);
                        b = false;
                    } else {
                        //NSLog(@"Base sample count: %i", baseSampleCount);
                        bitBuffer[bitCount] = 0;
                        bitCount++;
                    }
                }
            }
            samplesSinceZeroCrossing = 0;
        } else {
            samplesSinceZeroCrossing++;
        }
        i++;
    }
    
    NSMutableString *rawBinary = [[NSMutableString alloc] initWithString:@"raw binary1: "];
    
    if (bitCount > 192) {
        *res = malloc(sizeof(unsigned short) * bitCount);
        
        memcpy(*res, bitBuffer, bitCount * sizeof(unsigned short));
        
        rawBinary = [[NSMutableString alloc] initWithString:@"raw binary2: "];
        unsigned short *test = *res;
        for (i = 0; i < bitCount; i++) {
            if (test[i] == 1)
                [rawBinary appendString: @"1"];
            else
                [rawBinary appendString: @"0"];
        }
        
        NSLog(rawBinary);
        NSLog(@"Bit count: %i", bitCount);
    } else {
        *res = NULL;
    }
    
    
    free(bitBuffer);
    
    return bitCount;
}

void rioInterruptionListener(void *inClientData, UInt32 inInterruption)
{
	NSLog(@"Session interrupted! --- %s ---", inInterruption == kAudioSessionBeginInterruption ? "Begin Interruption" : "End Interruption");
	
	if (inInterruption == kAudioSessionEndInterruption) {
		// make sure we are again the active session
		AudioSessionSetActive(true);
		AudioOutputUnitStart(audioUnit);
	}
	
	if (inInterruption == kAudioSessionBeginInterruption) {
		AudioOutputUnitStop(audioUnit);
    }
}

static OSStatus recordingCallback(void *inRefCon,
                                  AudioUnitRenderActionFlags *ioActionFlags,
                                  const AudioTimeStamp *inTimeStamp,
                                  UInt32 inBusNumber,
                                  UInt32 inNumberFrames,
                                  AudioBufferList *ioData) {
    
    // This method just copies the audio from the mic to a buffer when it is louder than the setted threshold.
    AudioBufferList bufferList;
    
    bufferList.mNumberBuffers = 1;
    bufferList.mBuffers[0].mDataByteSize = inNumberFrames * 2;
    bufferList.mBuffers[0].mNumberChannels = 1;
    bufferList.mBuffers[0].mData = malloc(inNumberFrames * 2);
    
    OSStatus status;
    status = AudioUnitRender(audioUnit,
                             ioActionFlags,
                             inTimeStamp,
                             inBusNumber,
                             inNumberFrames,
                             &bufferList);
    checkStatus(status, @"AudioUnitRender");
    
    
    short *pData = bufferList.mBuffers[0].mData;
    int lastSilenceIndex = -1;
    int firstLoudIndex = -1;
    int i = 0;
    
    if (recording) {
        while (i < inNumberFrames && lastSilenceIndex < 0) {
            if (abs(pData[i]) < SILENCE_THRESHOLD) {
                silentSamplesCount++;
                if (silentSamplesCount > FREQ) {
                    lastSilenceIndex = i;
                }
            } else {
                silentSamplesCount = 0;
            }
            i++;
        }
        
        memcpy(&recordingBuffer[recordedSamplesCount], pData, inNumberFrames*2);
        recordedSamplesCount += inNumberFrames;
        
        pthread_mutex_lock(&mutex);
        if (lastSilenceIndex >= 0 || getRecordingStatus() != STATUS_RECORDING) {
            recording = false;
            NSLog(@"Stop recording-> recorded samples = %li", recordedSamplesCount);
            silentSamplesCount = 0;
            if (getRecordingStatus() == STATUS_RECORDING)
                setRecordingStatus(STATUS_DATA_PRESENT);
        }
        pthread_mutex_unlock(&mutex);
    } else {
        while (i < inNumberFrames && firstLoudIndex < 0) {
            if (abs(pData[i]) > SILENCE_THRESHOLD) {
                loudSamplesCount++;
                if (loudSamplesCount > QUORUM) {
                    firstLoudIndex = i;
                    loudSamplesCount = 0;
                }
            } else {
                loudSamplesCount = 0;
            }
            i++;
        }
        
        if (firstLoudIndex > 0) {
            loudSamplesCount = 0;
            pthread_mutex_lock(&mutex);
            if (getRecordingStatus() == STATUS_READY) {
                setRecordingStatus(STATUS_RECORDING);
                NSLog(@"Start recording");
                recording = true;
            }
            pthread_mutex_unlock(&mutex);
            
            if (recording) {
                memcpy(recordingBuffer, pData, inNumberFrames*2);
                recordedSamplesCount = inNumberFrames;
            }
        }
    }
    
    free(pData);
    
    // Now, we have the samples we just read sitting in buffers in bufferList
    return noErr;
}


void audioRouteChangeListenerCallback (
									   void                      *inUserData,
									   AudioSessionPropertyID    inPropertyID,
									   UInt32                    inPropertyValueSize,
									   const void                *inPropertyValue)
{
	if (inPropertyID != kAudioSessionProperty_AudioRouteChange)
		return;
	
	CFDictionaryRef    routeChangeDictionary = inPropertyValue;
	CFNumberRef routeChangeReasonRef = CFDictionaryGetValue (routeChangeDictionary,
															 CFSTR (kAudioSession_AudioRouteChangeKey_Reason));

	SInt32 routeChangeReason;
	CFNumberGetValue (routeChangeReasonRef, kCFNumberSInt32Type, &routeChangeReason);
	NSLog(@"RouteChangeReason : %ld", routeChangeReason);
	
	if (routeChangeReason == kAudioSessionRouteChangeReason_OldDeviceUnavailable) {
		NSLog(@"kAudioRouteChangeReason: OldDeviceUnavailable!\n");
	} else if (routeChangeReason == kAudioSessionRouteChangeReason_NewDeviceAvailable) {
		NSLog(@"kAudioRouteChangeReason: NewDeviceAvailable!\n");
	} else if (routeChangeReason == kAudioSessionRouteChangeReason_NoSuitableRouteForCategory) {
		NSLog(@"kAudioRouteChangeReason: lostMicroPhone");
	}
	else {
		NSLog(@"kAudioRouteChangeReason: unknown");
	}

}

- (void) init:(NSMutableArray*)arguments withDict:(NSMutableDictionary*)options
{
    OSStatus status = 0;
    
    //Init mutex
    pthread_mutex_init(&mutex, NULL);
    
    //Set up recording buffer. (Buffer the stripe data will be recorded in)
    RECORDING_BUFFER_SIZE = FREQ * 10; //10 seconds of recording
    recordingBuffer = (short *) malloc(RECORDING_BUFFER_SIZE);
    
	// Describe audio component
	AudioComponentDescription desc;
	desc.componentType = kAudioUnitType_Output;
	desc.componentSubType = kAudioUnitSubType_RemoteIO;
	desc.componentFlags = 0;
	desc.componentFlagsMask = 0;
	desc.componentManufacturer = kAudioUnitManufacturer_Apple;
	
	// Get component
	AudioComponent inputComponent = AudioComponentFindNext(NULL, &desc);
	
	// Get audio units
	status = AudioComponentInstanceNew(inputComponent, &audioUnit);
	checkStatus(status, @"AudioComponentInstanceNew");
	
	// Enable IO for recording
	UInt32 flag = 1;
	status = AudioUnitSetProperty(audioUnit,
								  kAudioOutputUnitProperty_EnableIO,
								  kAudioUnitScope_Input,
								  kInputBus,
								  &flag,
								  sizeof(flag));
	checkStatus(status, @"AudioUnitSetProperty");
    
    
	// Describe format
	AudioStreamBasicDescription audioFormat;
	audioFormat.mSampleRate			= FREQ;
	audioFormat.mFormatID			= kAudioFormatLinearPCM;
	audioFormat.mFormatFlags		= kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsNonInterleaved;
	audioFormat.mFramesPerPacket	= 1;
	audioFormat.mChannelsPerFrame	= 1;
	audioFormat.mBitsPerChannel		= 16;
	audioFormat.mBytesPerPacket		= 2;
	audioFormat.mBytesPerFrame		= 2;
	
	// Apply format
	status = AudioUnitSetProperty(audioUnit,
								  kAudioUnitProperty_StreamFormat,
								  kAudioUnitScope_Input,
								  kOutputBus,
								  &audioFormat,
								  sizeof(audioFormat));
	checkStatus(status, @"AudioUnitSetProperty");
    
    
    // Apply format
	status = AudioUnitSetProperty(audioUnit,
								  kAudioUnitProperty_StreamFormat,
								  kAudioUnitScope_Output,
								  kInputBus,
								  &audioFormat,
								  sizeof(audioFormat));
	checkStatus(status, @"AudioUnitSetProperty");
    
    // Set input callback
    AURenderCallbackStruct icallbackStruct;
    icallbackStruct.inputProc = recordingCallback;
    icallbackStruct.inputProcRefCon = self;
    status = AudioUnitSetProperty(audioUnit,
                                  kAudioOutputUnitProperty_SetInputCallback,
                                  kAudioUnitScope_Output,
                                  kInputBus,
                                  &icallbackStruct,
                                  sizeof(icallbackStruct));
	
    
	NSLog(@"AudioUnit Sample Rate = %lf", audioFormat.mSampleRate);

    
	
	// Initialise
	NSLog(@"AudioUnitInitialize");
	status = AudioUnitInitialize(audioUnit);
	checkStatus(status, @"AudioUnitInitialize");
    
    
	AudioSessionInitialize(NULL, NULL, rioInterruptionListener, self);
	UInt32 audioCategory = kAudioSessionCategory_PlayAndRecord;
	AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(audioCategory), &audioCategory);
	AudioSessionAddPropertyListener (kAudioSessionProperty_AudioRouteChange,
                                     audioRouteChangeListenerCallback,
                                     self);
	AudioSessionSetActive(true);
    
    CDVPluginResult* pluginResult = nil;
    NSString* javaScript = nil;
    
    setRecordingStatus(STATUS_READY);
    
    NSString* callbackId = [arguments objectAtIndex:0];
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"read stopped"];
    javaScript = [pluginResult toSuccessCallbackString:callbackId];
    [self writeJavascript:javaScript];

}

int decodeBits(unsigned short *bitSequence, int i, int len, short d) {
    int value = 0;
    int j;
    int k;
    int w = 0;
    for (j = 0; j < len; j++) {
        if (d > 0) {
            k = i + j;
        } else {
            k = i - j;
        }
        NSLog(@"%i", value);
        if (bitSequence[k] > 0)
            value += (1 << w);
        
        w++;
    }
    NSLog(@"%i", value);
    
    
    return value;
}

NSString *decodeToASCII(unsigned short *bitSequence, int size, short d) {
    int i = 0;
    int j;
    int first1 = -1;
    
    if (bitSequence == NULL)
        return NULL;
    
    NSMutableString *res;
    
    while (i < size && first1 < 0) {
        if (d < 0)
            j = size - i - 1;
        else
            j = i;
        
        
        if (bitSequence[j] == 1)
            first1 = j;
        
        i++;
    }
    
    if (first1 < 0) //Sequence is all 0s - Reading error!
        return NULL;
    
    NSLog(@"First one bit at: %i", first1);
    
    int bitEncoding;
    int baseChar;
    NSLog(@"Start decoding, d: %i", d);
    //Sentinel test;
    if (decodeBits(bitSequence, first1, 4, d) == 11) {
        //found 5 bit encoding sentinel.
        NSLog(@"Found sentinel for 5 bit encoding");
        bitEncoding = 4;
        baseChar = 48;
    } else if (decodeBits(bitSequence, first1, 5, d) == 5) {
        //found 6 bit encoding sentinel.
        NSLog(@"Found sentinel for 6 bit encoding");
        bitEncoding = 5;
        baseChar = 32;
    } else {
        //No sentinel found.
        NSLog(@"No sentinel found");
        return NULL;
    }
    
    res = [[NSMutableString alloc] initWithString:@"data: "];
    
    i = first1;
    char c;
    NSString *s;
    bool foundEndSentinel = false;
    while (i < size && !foundEndSentinel) {
        if (d < 0)
            j = size - i - 1;
        else
            j = i;
        
        c = (char) (decodeBits(bitSequence, j, bitEncoding, d) + baseChar);
        s = [NSString stringWithFormat:@"%c", c];
        
        [res appendString: s];
        
        if (c == '?')
            foundEndSentinel = true;
        
        i += bitEncoding + 1; //+1 cause we discard parity bit
    }
    
    return res;
}

/*
 VALID CARD DATA nv
 00000000000000110101010101000100111100101000100110001010101110011000010101000100100000001000101100110110100000010010000010001000000001100000000101101000011000001101011011100111001001000010010000000100001011111001000000000000
 
 */
-(void) getStatus:(NSMutableArray *)arguments withDict:(NSMutableDictionary *)options
{
    NSString* callbackId = [arguments objectAtIndex:0];
    
    CDVPluginResult* pluginResult = nil;
    NSString* javaScript = nil;
    
    @try {
        pthread_mutex_lock(&mutex);
        if (getRecordingStatus() == STATUS_READY) {
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"{status: ready}"];
            javaScript = [pluginResult toSuccessCallbackString:callbackId];
            pthread_mutex_unlock(&mutex);
        } else if (getRecordingStatus() == STATUS_RECORDING) {
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"{status: recording}"];
            javaScript = [pluginResult toSuccessCallbackString:callbackId];
            pthread_mutex_unlock(&mutex);
        } else if (getRecordingStatus() == STATUS_DATA_PRESENT) {
            //copy buffer so we can release mutex before processing.
            long size = recordedSamplesCount;
            short *dataBuffer = malloc(sizeof(short) * recordedSamplesCount);
            memcpy(dataBuffer, recordingBuffer, recordedSamplesCount * sizeof(short));
            pthread_mutex_unlock(&mutex);
            
            short minLevel = getMinLevel(dataBuffer, size);
            unsigned short *bitSequence;
            int bitCount = decodeRawDataToBitSet(dataBuffer, size, &bitSequence, minLevel);
            
            
            NSString *res = decodeToASCII(bitSequence, bitCount, -1);
            if (res == NULL) {
                res = decodeToASCII(bitSequence, bitCount, 1);
            }
            
            /*
            if (res == NULL) {
                bitCount = decodeRawDataToBitSetPeakMethod(dataBuffer, size, &bitSequence, minLevel);
            
                res = decodeToASCII(bitSequence, bitCount, -1);
                if (res == NULL) {
                    res = decodeToASCII(bitSequence, bitCount, 1);
                }
            }*/
            
            NSMutableString *msg = [NSMutableString stringWithString:@"{status: data_present, "];
            
            if (res != NULL) {
                [msg appendString: res];
            } else {
                [msg appendString: @"data: data_error"];
            }
            
            [msg appendString: @"}"];
            
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString: msg];
            javaScript = [pluginResult toSuccessCallbackString:callbackId];
            
            if (bitSequence != NULL)
                free(bitSequence); //memory is now mine!
            
            free(dataBuffer);
        } else {
            pthread_mutex_unlock(&mutex);
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR];
            javaScript = [pluginResult toErrorCallbackString:callbackId];
        }
        
    } @catch (NSException* exception) {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_JSON_EXCEPTION messageAsString:[exception reason]];
        javaScript = [pluginResult toErrorCallbackString:callbackId];
    }
    
    [self writeJavascript:javaScript];
}

-(void) startRead:(NSMutableArray *)arguments withDict:(NSMutableDictionary *)options
{
    OSStatus status = 0;
    
    CDVPluginResult* pluginResult = nil;
    NSString* javaScript = nil;
    
    pthread_mutex_lock(&mutex);
    setRecordingStatus(STATUS_READY);
    pthread_mutex_unlock(&mutex);
    
	//start audio unit
	NSLog(@"AudioOutputUnitStart");
	status = AudioOutputUnitStart(audioUnit);
	checkStatus(status, @"AudioUnitStart");
    
    NSString* callbackId = [arguments objectAtIndex:0];
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"read started"];
    javaScript = [pluginResult toSuccessCallbackString:callbackId];
    [self writeJavascript:javaScript];
}

-(void) stopRead:(NSMutableArray *)arguments withDict:(NSMutableDictionary *)options
{
    OSStatus status = 0;
    
    CDVPluginResult* pluginResult = nil;
    NSString* javaScript = nil;
    
    pthread_mutex_lock(&mutex);
    setRecordingStatus(STATUS_READY);
    pthread_mutex_unlock(&mutex);
    
	NSLog(@"AudioOutputUnitStop");
	status = AudioOutputUnitStop(audioUnit);
	checkStatus(status, @"AudioUnitStop");
    
    NSString* callbackId = [arguments objectAtIndex:0];
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"read stopped"];
    javaScript = [pluginResult toSuccessCallbackString:callbackId];
    [self writeJavascript:javaScript];
}

@end
