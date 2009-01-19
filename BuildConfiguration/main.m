/*
 * Copyright (c) 2008-2009 XMeeting Project ("http://xmeeting.sf.net").
 * All rights reserved.
 * Copyright (c) 2008-2009 Hannes Friederich. All rights reserved.
 *
 * $Revision$
 * $Author$
 * $Date$
 */

#import <Cocoa/Cocoa.h>
#import <sys/param.h>
#import <sys/sysctl.h>
#import <string.h>
#import <stdlib.h>

/**
 * The purpose of this little application is to replace the OPAL configuration chain (autoconf).
 * This is needed since this project does not build PTLib / OPAL separately, but instead includes everything
 * into one binary. Unfortunately, as of November 2008, the autofonf chain requires a ptlib binary in order
 * to build opal. Hence, this little app was created to allow seamless integration of PTLib / OPAL into the
 * XMeeting build system.
 *
 * Perhaps a shell script would be more appropriate for this task, but the author is much more familiar with
 * programming Obj-C/C/C++ than programming shell scripts...
 **/

typedef struct ReplaceRecord {
  NSString *search;
  NSString *replacement;
} ReplaceRecord;

typedef struct FileDefinition {
  NSString *templateFile;
  NSString *outputFile;
  ReplaceRecord *replaceRecords;
  unsigned numReplaceRecords;
} FileDefinition;

NSString *PTLIBTemplateFile = @"../ptlib/include/ptbuildopts.h.in";
NSString *PTLIBOutputFile = @"../ptlib/include/ptbuildopts.h";
NSString *PTLIBVersionFile = @"../ptlib/version.h";
NSString *PTLibDataFile = @"BuildConfiguration/PTLibData.plist";

NSString *OPALTemplateFile = @"../opal/include/opal/buildopts.h.in";
NSString *OPALOutputFile = @"../opal/include/opal/buildopts.h";
NSString *OPALVersionFile = @"../opal/version.h";
NSString *OPALDataFile = @"BuildConfiguration/OPALData.plist";

NSString *OSVersionMajor;
NSString *OSVersionMinor;

NSString *PTLibVersionMajor;
NSString *PTLibVersionMinor;
NSString *PTLibVersionBuild;

NSString *OPALVersionMajor;
NSString *OPALVersionMinor;
NSString *OPALVersionBuild;

void getDarwinVersion(unsigned *major, unsigned *minor);
void getPTLIBVersion(unsigned *major, unsigned *minor, unsigned *build);
void getOPALVersion(unsigned *major, unsigned *minor, unsigned *build);
int processFile(NSString *templateFile, NSString *outputFile, NSString *dataFile);
void processKey(NSMutableString *str, NSString *key, NSString *replacement);

int main(int argc, char *argv[])
{
  NSAutoreleasePool *autoreleasePool = [[NSAutoreleasePool alloc] init];
  
  // Obtain OS version information
  unsigned versionMajor, versionMinor, versionBuild;
  getDarwinVersion(&versionMajor, &versionMinor);
  OSVersionMajor = [[NSString alloc] initWithFormat:@"%d", versionMajor];
  OSVersionMinor = [[NSString alloc] initWithFormat:@"%02d", versionMinor];
  
  // Obtain PTLib version information
  getPTLIBVersion(&versionMajor, &versionMinor, &versionBuild);
  PTLibVersionMajor = [[NSString alloc] initWithFormat:@"%d", versionMajor];
  PTLibVersionMinor = [[NSString alloc] initWithFormat:@"%d", versionMinor];
  PTLibVersionBuild = [[NSString alloc] initWithFormat:@"%d", versionBuild];
  
  // Obtain OPAL version information
  getOPALVersion(&versionMajor, &versionMinor, &versionBuild);
  OPALVersionMajor = [[NSString alloc] initWithFormat:@"%d", versionMajor];
  OPALVersionMinor = [[NSString alloc] initWithFormat:@"%d", versionMinor];
  OPALVersionBuild = [[NSString alloc] initWithFormat:@"%d", versionBuild];
  
  int result = 0;
  
  // process the PTLIB file
  NSLog(@"Processing the PTLIB file");
  result = processFile(PTLIBTemplateFile, PTLIBOutputFile, PTLibDataFile);
  if (result != 0) {
    NSLog(@"Could not process the PTLIB file (%d)", result);
    goto bail;
  }
  
  // process the OPAL file
  NSLog(@"Processing the OPAL file");
  result = processFile(OPALTemplateFile, OPALOutputFile, OPALDataFile);
  if (result != 0) {
    NSLog(@"Could not process the OPAL file (%d)", result);
    goto bail;
  }
  
  NSLog(@"All files processed");
  
bail:
  [autoreleasePool release];
  [OSVersionMajor release];
  [OSVersionMinor release];
  [PTLibVersionMajor release];
  [PTLibVersionMinor release];
  [PTLibVersionBuild release];
  [OPALVersionMajor release];
  [OPALVersionMinor release];
  [OPALVersionBuild release];
  
  return result;
}

int processFile(NSString *templateFile, NSString *outputFile, NSString *dataFile)
{
  NSError *error;
  NSString *template = [NSString stringWithContentsOfFile:templateFile encoding:NSASCIIStringEncoding error:&error];
  if (template == nil) {
    NSLog(@"Could not open template file '%@' (%@)", templateFile, [error localizedDescription]);
    return 1;
  }
  NSMutableString *outputString = [template mutableCopy];
  
  NSString *errorString;
  NSData *data = [NSData dataWithContentsOfFile:dataFile];
  if (data == nil) {
    NSLog(@"Could not open data file");
    return 2;
  }
  NSDictionary *dict = [NSPropertyListSerialization propertyListFromData:data mutabilityOption:NSPropertyListImmutable format:NULL errorDescription:&errorString];
  if (dict == nil) {
    NSLog(@"Could not read data file (%@)", errorString);
    return 3;
  }
  NSEnumerator *enumerator = [dict keyEnumerator];
  NSString *key;
  while ((key = [enumerator nextObject]) != nil) {
    NSString *value = [dict objectForKey:key];
    processKey(outputString, key, value);
  }
  
  [outputString replaceOccurrencesOfString:@"__XM_OS_MAJOR__" withString:OSVersionMajor options:NSLiteralSearch range:NSMakeRange(0, [outputString length])];
  [outputString replaceOccurrencesOfString:@"__XM_OS_MINOR__" withString:OSVersionMinor options:NSLiteralSearch range:NSMakeRange(0, [outputString length])];
  [outputString replaceOccurrencesOfString:@"__XM_PTLIB_MAJOR__" withString:PTLibVersionMajor options:NSLiteralSearch range:NSMakeRange(0, [outputString length])];
  [outputString replaceOccurrencesOfString:@"__XM_PTLIB_MINOR__" withString:PTLibVersionMinor options:NSLiteralSearch range:NSMakeRange(0, [outputString length])];
  [outputString replaceOccurrencesOfString:@"__XM_PTLIB_BUILD__" withString:PTLibVersionBuild options:NSLiteralSearch range:NSMakeRange(0, [outputString length])];
  [outputString replaceOccurrencesOfString:@"__XM_OPAL_MAJOR__" withString:OPALVersionMajor options:NSLiteralSearch range:NSMakeRange(0, [outputString length])];
  [outputString replaceOccurrencesOfString:@"__XM_OPAL_MINOR__" withString:OPALVersionMinor options:NSLiteralSearch range:NSMakeRange(0, [outputString length])];
  [outputString replaceOccurrencesOfString:@"__XM_OPAL_BUILD__" withString:OPALVersionBuild options:NSLiteralSearch range:NSMakeRange(0, [outputString length])];
  
  if (![outputString writeToFile:outputFile atomically:YES encoding:NSASCIIStringEncoding error:&error]) {
    NSLog(@"Could not write '%@' (%@)", outputFile, [error localizedDescription]);
    return 4;
  }
  
  return 0;
}

void getDarwinVersion(unsigned *systemVersionMajor, unsigned *systemVersionMinor)
{
  int mib[2];
  size_t len;
  char *kernelVersion;
  
  mib[0] = CTL_KERN;
  mib[1] = KERN_OSRELEASE;
  
  sysctl(mib, 2, NULL, &len, NULL, 0);
  kernelVersion = malloc(len * sizeof(char));
  sysctl(mib, 2, kernelVersion, &len, NULL, 0);
  
  NSString *content = [NSString stringWithCString:kernelVersion encoding:NSASCIIStringEncoding];
  NSScanner *scanner = [NSScanner scannerWithString:content];
  [scanner scanInt:(int *)systemVersionMajor];
  [scanner scanString:@"." intoString:NULL];
  [scanner scanInt:(int *)systemVersionMinor];
  
  free(kernelVersion);
}

void getPTLIBVersion(unsigned *major, unsigned *minor, unsigned *build)
{
  NSString *text = [NSString stringWithContentsOfFile:PTLIBVersionFile encoding:NSASCIIStringEncoding error:NULL];
  if (text == nil) {
    return;
  }
  NSScanner *scanner = [NSScanner scannerWithString:text];
  [scanner scanUpToString:@"MAJOR_VERSION " intoString:NULL];
  [scanner scanString:@"MAJOR_VERSION " intoString:NULL];
  if (![scanner scanInt:(int*)major]) {
    return;
  }
  [scanner scanUpToString:@"MINOR_VERSION " intoString:NULL];
  [scanner scanString:@"MINOR_VERSION " intoString:NULL];
  if (![scanner scanInt:(int*)minor]) {
    return;
  }
  [scanner scanUpToString:@"BUILD_NUMBER " intoString:NULL];
  [scanner scanString:@"BUILD_NUMBER " intoString:NULL];
  if (![scanner scanInt:(int*)build]) {
    return;
  }
}

void getOPALVersion(unsigned *major, unsigned *minor, unsigned *build)
{
  NSString *text = [NSString stringWithContentsOfFile:OPALVersionFile encoding:NSASCIIStringEncoding error:NULL];
  if (text == nil) {
    return;
  }
  NSScanner *scanner = [NSScanner scannerWithString:text];
  [scanner scanUpToString:@"MAJOR_VERSION " intoString:NULL];
  [scanner scanString:@"MAJOR_VERSION " intoString:NULL];
  if (![scanner scanInt:(int*)major]) {
    return;
  }
  [scanner scanUpToString:@"MINOR_VERSION " intoString:NULL];
  [scanner scanString:@"MINOR_VERSION " intoString:NULL];
  if (![scanner scanInt:(int*)minor]) {
    return;
  }
  [scanner scanUpToString:@"BUILD_NUMBER " intoString:NULL];
  [scanner scanString:@"BUILD_NUMBER " intoString:NULL];
  if (![scanner scanInt:(int*)build]) {
    return;
  }
}

void processKey(NSMutableString *str, NSString *key, NSString *replacement)
{
  NSAutoreleasePool *autoreleasePool = [[NSAutoreleasePool alloc] init];
  
  // create the correct replacement string
  if ([replacement length] == 0) {
    replacement = [NSString stringWithFormat:@"/* #undef %@ */\n", key];
  } else {
    replacement = [NSString stringWithFormat:@"#define %@ %@\n", key, replacement];
  }
  
  NSCharacterSet *emptyCS = [NSCharacterSet illegalCharacterSet];
  NSCharacterSet *wsCS = [NSCharacterSet whitespaceCharacterSet];
  
  // the best way would be to use some regexp. However, as cocoa has no native
  // support for it, lets use NSScanner for this task instead of spending time
  // on integrating another library
  NSScanner *scanner = [NSScanner scannerWithString:str];
  [scanner setCharactersToBeSkipped:emptyCS];
  while (![scanner isAtEnd]) {
    [scanner scanUpToString:@"#undef" intoString:NULL];
    unsigned startLocation = [scanner scanLocation];
    [scanner scanString:@"#undef" intoString:NULL];
    [scanner scanCharactersFromSet:wsCS intoString:NULL];
    if ([scanner scanString:key intoString:NULL]) {
      // remove whitespace (if any) 
      [scanner scanCharactersFromSet:[NSCharacterSet whitespaceCharacterSet] intoString:NULL];
      
      // ensure that indeed the key is found. If yes, then the next character is a newline
      if ([scanner scanString:@"\n" intoString:NULL]) {
        // correct key found
        unsigned endLocation = [scanner scanLocation];
      
        NSRange range = NSMakeRange(startLocation, endLocation-startLocation);
        [str replaceCharactersInRange:range withString:replacement];
        [scanner setScanLocation:startLocation]; // move scanner back to ensure all occurrences of key are found
        
        // create a new scanner object, as the old one points to an invalid string
        unsigned newStartLocation = startLocation + [replacement length];
        scanner = [NSScanner scannerWithString:str];
        [scanner setScanLocation:newStartLocation];
      }
    }
  }
  
  [autoreleasePool release];
}
