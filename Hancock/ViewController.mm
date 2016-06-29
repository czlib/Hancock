//
//  ViewController.m
//  CertAndSign
//
//  Created by Jeremy Agostino on 6/27/16.
//  Copyright © 2016 GroundControl. All rights reserved.
//

#import "ViewController.h"
#import <Security/Security.h>

@implementation ViewController

/*
 * Sets up some UI elements and initializes other members
 */

- (void)viewDidLoad
{
	[super viewDidLoad];
	
	[self.spinner setHidden:YES];
	
	[self.popup removeAllItems];
	
	self.title = @"Hancock - Signing Tool";
	self.signButton.title = @"Sign...";
	self.unsignButton.title = @"Unsign...";
	
	[self validateButtons];
	
	self.loadedIdentities = [NSMutableArray new];

	dispatch_async(dispatch_get_global_queue(0, 0), ^{
		[self loadIdentities];
	});
}

- (void)setRepresentedObject:(id)representedObject
{
	[super setRepresentedObject:representedObject];
	
	[self validateButtons];
}

/*
 * The Sign... button is only enabled if there is an identity in the list to be selected
 */

- (void)validateButtons
{
	self.popup.enabled = self.popup.numberOfItems > 0;
	self.signButton.enabled = self.popup.enabled;
}

/*
 * Helper that makes an NSOpenPanel useful for choosing single files
 */

static NSOpenPanel * _CreateOpenPanel()
{
	auto openPanel = [NSOpenPanel new];
	openPanel.canChooseFiles = YES;
	openPanel.canChooseDirectories = NO;
	openPanel.canCreateDirectories = NO;
	openPanel.allowsMultipleSelection = NO;
	return openPanel;
}

/*
 * Sign... button action handler that prompts for a file and invokes the signFile:withIdentity: method
 */

- (IBAction)actionSignFile:(id)sender
{
	auto openPanel = _CreateOpenPanel();
	openPanel.title = @"Choose a file to sign";
	auto result = [openPanel runModal];
	
	if (result == NSFileHandlingPanelOKButton) {
		// Make local ref so we can use them on a global queue without race condition
		auto signFileURL = openPanel.URL;
		
		SecIdentityRef chosenIdentity = [self copySelectedIdentity];
		
		if (signFileURL != nil) {
			
			if (chosenIdentity != nullptr) {
				
				dispatch_async(dispatch_get_global_queue(0, 0), ^{
					
					[self startSpinning];
					
					[self signFile:signFileURL withIdentity:chosenIdentity];
					
					[self stopSpinning];
					
					CFRelease(chosenIdentity);
				});
			}
		}
	}
}

/*
 * Unsign... button action handler that prompts for a file and invokes the unsignFile: method
 */

- (IBAction)actionUnsignFile:(id)sender
{
	auto openPanel = _CreateOpenPanel();
	openPanel.title = @"Choose a file to unsign";
	auto result = [openPanel runModal];
	
	if (result == NSFileHandlingPanelOKButton) {
		// Make local ref so we can use them on a global queue without race condition
		auto fileURL = openPanel.URL;
		
		if (fileURL != nil) {
			
			dispatch_async(dispatch_get_global_queue(0, 0), ^{
				
				[self startSpinning];
				
				[self unsignFile:fileURL];
				
				[self stopSpinning];
			});
		}
	}
}

/*
 * Gets the identity object for the item currently selected in the list
 */

- (SecIdentityRef)copySelectedIdentity
{
	auto chosenIndex = self.popup.indexOfSelectedItem;
	
	if (chosenIndex >= self.loadedIdentities.count) {
		return nullptr;
	}
	
	return (SecIdentityRef)CFBridgingRetain(self.loadedIdentities[chosenIndex]);
}

/*
 * External method that can be used to invoke the sign action on a filename we got elsewhere
 */

- (void)handleDraggedFilename:(NSString *)filename
{
	auto chosenIdentity = [self copySelectedIdentity];
	
	if (chosenIdentity != nullptr) {
		
		dispatch_async(dispatch_get_global_queue(0, 0), ^{
			
			[self startSpinning];
			
			[self signFile:[NSURL fileURLWithPath:filename] withIdentity:chosenIdentity];
			
			[self stopSpinning];
			
			CFRelease(chosenIdentity);
		});
	}
}

/*
 * Loads the popup list by asking Keychain for all identities and getting their certs' name and serial number for display
 * Also populates an array member with the valid identities so we can sign with a chosen one later
 */

- (void)loadIdentities
{
	// Ask for basically all identities in the keychain
	auto query = @{
				   (__bridge NSString *)kSecClass:(__bridge NSString *)kSecClassIdentity,
				   (__bridge NSString *)kSecReturnRef: @(YES),
				   (__bridge NSString *)kSecMatchLimit: (__bridge NSString *)kSecMatchLimitAll,
				   };
	
	OSStatus oserr;
	CFArrayRef identsCF = NULL;
	oserr = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&identsCF);
	
	if (oserr != 0) {
		NSString * err = CFBridgingRelease(SecCopyErrorMessageString(oserr, nullptr));
		[self showAlertWithMessage:@"Failed to Load Identities" informativeText:[NSString stringWithFormat:@"An internal error occurred while loading identities to list for signing. Security says: %@.", err]];
		return;
	}
	
	// Clear the array and popup menu
	dispatch_async(dispatch_get_main_queue(), ^{
		[self.loadedIdentities removeAllObjects];
		[self.popup removeAllItems];
	});
	
	NSArray * idents = CFBridgingRelease(identsCF);
	for (id ident in idents) {
		
		// The certificate has the useful metadata for display
		SecCertificateRef cert = nullptr;
		oserr = SecIdentityCopyCertificate((__bridge SecIdentityRef)ident, &cert);
		
		if (cert == nullptr) {
			continue;
		}
		
		CFStringRef nameCF = nullptr;
		oserr = SecCertificateCopyCommonName(cert, &nameCF);
		
		CFDataRef serialCF = SecCertificateCopySerialNumber(cert, nullptr);
		
		CFRelease(cert);
		
		NSString * name = CFBridgingRelease(nameCF);
		NSData * serial = CFBridgingRelease(serialCF);
		
		if (name.length > 0 && serial.length > 0) {
			
			// Sometimes the serial number is less than 64 bits, in which case I zero-pad it
			if (serial.length < sizeof(SInt64)) {
				auto temp = [NSMutableData new];
				[temp increaseLengthBy:sizeof(SInt64) - serial.length];
				[temp appendData:serial];
				serial = temp;
			}
			
			// Keychain displays the serial number as a big-endian 64-bit signed integer
			// So swap it and make a number
			SInt64 serialBig = CFSwapInt64HostToBig(*((SInt64*)serial.bytes));
			NSNumber * serialNumber = CFBridgingRelease(CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &serialBig));
			
			// Popup menu item title is the name of the cert followed by serial number
			NSString * title = [NSString stringWithFormat:@"%@ [%@]", name, serialNumber];
			
			// Add this identity to the array and popup menu
			dispatch_async(dispatch_get_main_queue(), ^{
				
				// Popups can only contains unique titles so make sure there are no dupes
				if (![self.popup.itemTitles containsObject:title]) {
					[self.loadedIdentities addObject:ident];
					[self.popup addItemWithTitle:title];
				}
			});
		}
	}
	
	dispatch_async(dispatch_get_main_queue(), ^{
		[self validateButtons];
	});
}

/*
 * This method signs a file with the given identity and prompts the user where to save it
 */

- (void)signFile:(NSURL*)fileURL withIdentity:(SecIdentityRef)chosenIdentity
{
	auto data = [NSData dataWithContentsOfURL:fileURL];
	if (data.length == 0) {
		[self showAlertWithMessage:@"No File Selected" informativeText:@"Please select a file to sign with the chosen identity."];
		return;
	}
	
	OSStatus oserr;
	
	// This method simply signs data when given an identity
	// It may generate a user prompt for permission to sign
	CFDataRef outDataCF = NULL;
	oserr = CMSEncodeContent(chosenIdentity, NULL, NULL, false, kCMSAttrNone,
							 data.bytes, data.length, &outDataCF);
	
	if (oserr != 0) {
		NSString * err = oserr == -1 ? @"Permission to sign with identitiy was denied" : CFBridgingRelease(SecCopyErrorMessageString(oserr, nullptr));
		[self showAlertWithMessage:@"Signing Failed" informativeText:[NSString stringWithFormat:@"An internal error occurred while attempting to sign '%@'. Security says: %@.", fileURL.lastPathComponent, err]];
		return;
	}
	
	NSData * outData = CFBridgingRelease(outDataCF);
	auto newFilename = [self filenameForURL:fileURL withAppendedString:@"Signed"];
	
	// Display a save box with a new default filename
	dispatch_async(dispatch_get_main_queue(), ^{
		
		auto savePanel = [NSSavePanel new];
		savePanel.canCreateDirectories = YES;
		savePanel.nameFieldStringValue = newFilename;
		savePanel.title = @"Choose where to save signed data";
		
		if ([savePanel runModal] == NSFileHandlingPanelOKButton) {
			auto saveURL = savePanel.URL;
			[outData writeToURL:saveURL atomically:YES];
		}
	});
}

/*
 * This method unsigns a file and prompts the user where to save it
 */

- (void)unsignFile:(NSURL*)fileURL
{
	auto data = [NSData dataWithContentsOfURL:fileURL];
	if (data.length == 0) {
		[self showAlertWithMessage:@"No File Selected" informativeText:@"Please select a CMS encoded file to unsign."];
		return;
	}
	
	CMSDecoderRef decoder = NULL;
	CFDataRef outDataCF = NULL;
	
	// Create a decoder, add the data, finalize and retrieve the resulting data
	// If the data isn't signed, an error code will be returned along the way
	OSStatus oserr = CMSDecoderCreate(&decoder);
	if (oserr == noErr) {
		oserr = CMSDecoderUpdateMessage(decoder, data.bytes, data.length);
	}
	if (oserr == noErr) {
		oserr = CMSDecoderFinalizeMessage(decoder);
	}
	if (oserr == noErr) {
		oserr = CMSDecoderCopyContent(decoder, &outDataCF);
	}
	
	NSData * outData = CFBridgingRelease(outDataCF);
	
	if (oserr == noErr && outData.length > 0) {
		// Decoding succeeded
		auto newFilename = [self filenameForURL:fileURL withAppendedString:@"Unsigned"];
		
		// Display a save box with a new default filename
		dispatch_async(dispatch_get_main_queue(), ^{
			
			auto savePanel = [NSSavePanel new];
			savePanel.canCreateDirectories = YES;
			savePanel.nameFieldStringValue = newFilename;
			savePanel.title = @"Choose where to save unsigned data";
			
			if ([savePanel runModal] == NSFileHandlingPanelOKButton) {
				auto saveURL = savePanel.URL;
				[outData writeToURL:saveURL atomically:YES];
			}
		});
	}
	else {
		[self showAlertWithMessage:@"Failed to Unsign" informativeText:[NSString stringWithFormat:@"The selected file '%@' is probably not a CMS encoded (signed) file.", fileURL.lastPathComponent]];
	}
}

/*
 * Generates a new filename based on a URL with a string appended to it after a hyphen
 */

- (NSString *)filenameForURL:(NSURL*)fileURL withAppendedString:(NSString*)append
{
	auto originalFilename = fileURL.lastPathComponent;
	auto basename = [originalFilename stringByDeletingPathExtension];
	
	return [NSString stringWithFormat:@"%@-%@.%@", basename, append, originalFilename.pathExtension];
}

/*
 * Increment the count of active jobs and start the spinner if needed
 */

- (void)startSpinning
{
	dispatch_async(dispatch_get_main_queue(), ^{
		
		if (self.spinCount == 0) {
			[self.spinner setHidden:NO];
			[self.spinner startAnimation:self];
		}
		
		self.spinCount++;
	});
}

/*
 * Decrement the count of active jobs and stop the spinner if needed
 */

- (void)stopSpinning
{
	dispatch_async(dispatch_get_main_queue(), ^{
		
		self.spinCount--;
		
		if (self.spinCount == 0) {
			[self.spinner setHidden:YES];
			[self.spinner stopAnimation:self];
		}
	});
}

/*
 * Convenience method for showing an alert box
 */

- (void)showAlertWithMessage:(NSString*)message informativeText:(NSString*)informativeText
{
	dispatch_async(dispatch_get_main_queue(), ^{
		auto alert = [NSAlert new];
		alert.messageText = message;
		alert.informativeText = informativeText;
		[alert runModal];
	});
}

@end