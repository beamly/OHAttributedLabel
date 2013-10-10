/***********************************************************************************
 * This software is under the MIT License quoted below:
 ***********************************************************************************
 *
 * Copyright (c) 2010 Olivier Halligon
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 *
 ***********************************************************************************/


#import "OHAttributedLabel.h"
#import "CoreTextUtils.h"
#import "OHTouchesGestureRecognizer.h"

#ifndef OHATTRIBUTEDLABEL_WARN_ABOUT_KNOWN_ISSUES
#define OHATTRIBUTEDLABEL_WARN_ABOUT_KNOWN_ISSUES 1
#endif
#ifndef OHATTRIBUTEDLABEL_WARN_ABOUT_OLD_API
#define OHATTRIBUTEDLABEL_WARN_ABOUT_OLD_API 1
#endif

#if ! defined(COCOAPODS) && ! defined(OHATTRIBUTEDLABEL_DEDICATED_PROJECT)
// Copying files in your project and thus compiling OHAttributedLabel under different build settings
// than the one provided is not recommended and increase risks of leaks (mixing ARC vs. MRC) or unwanted behaviors
#warning [OHAttributedLabel integration] You should include OHAttributedLabel project in your workspace instead of copying the files in your own app project. Or better, use CocoaPods to integrate your 3rd party libs. See README for instructions.
#endif

#if __has_feature(objc_arc)
#define BRIDGE_CAST __bridge
#define MRC_RETAIN(x) (x)
#define MRC_RELEASE(x)
#define MRC_AUTORELEASE(x) (x)
#else
#define BRIDGE_CAST
#define MRC_RETAIN(x) [x retain]
#define MRC_RELEASE(x) [x release]; x = nil
#define MRC_AUTORELEASE(x) [x autorelease]
#endif

/////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Private interface
/////////////////////////////////////////////////////////////////////////////////////


const int UITextAlignmentJustify = ((UITextAlignment)kCTJustifiedTextAlignment);

@interface OHAttributedLabel(/* Private */) <UIGestureRecognizerDelegate>
{
	NSAttributedString* _attributedText;
    NSAttributedString* _attributedTextWithLinks;
    BOOL _needsRecomputeLinksInText;
    NSDataDetector* _linksDetector;
	CTFrameRef textFrame;
	CGRect drawingRect;
	NSMutableArray* _customLinks;
	CGPoint _touchStartPoint;
    UIGestureRecognizer *_gestureRecogniser;
    CTFramesetterRef _measuringFramesetter;
}
@property(nonatomic, retain) NSTextCheckingResult* activeLink;
-(NSTextCheckingResult*)linkAtCharacterIndex:(CFIndex)idx;
-(NSTextCheckingResult*)linkAtPoint:(CGPoint)pt;
-(void)resetTextFrame;
-(void)drawActiveLinkHighlightForRect:(CGRect)rect;
-(void)recomputeLinksInTextIfNeeded;
#if OHATTRIBUTEDLABEL_WARN_ABOUT_KNOWN_ISSUES
-(void)warnAboutKnownIssues_CheckLineBreakMode_FromXIB:(BOOL)fromXIB;
-(void)warnAboutKnownIssues_CheckAdjustsFontSizeToFitWidth_FromXIB:(BOOL)fromXIB;
#endif
@end

NSDataDetector* sharedReusableDataDetector(NSTextCheckingTypes types);



/////////////////////////////////////////////////////////////////////////////////////
#pragma mark - NSDataDetector Reusable Pool
/////////////////////////////////////////////////////////////////////////////////////

NSDataDetector* sharedReusableDataDetector(NSTextCheckingTypes types)
{
    static NSCache* dataDetectorsCache = nil;
    if (!dataDetectorsCache)
    {
        dataDetectorsCache = [[NSCache alloc] init];
        dataDetectorsCache.name = @"OHAttributedLabel::DataDetectorCache";
    }
    
    NSDataDetector* dd = nil;
    if (types > 0)
    {
        // Dequeue a reusable data detector from the pool, only allocate one if none exist yet
        id typesKey = [NSNumber numberWithUnsignedLongLong:types];
        dd = [dataDetectorsCache objectForKey:typesKey];
        if (!dd)
        {
            dd = [NSDataDetector dataDetectorWithTypes:types error:nil];
            [dataDetectorsCache setObject:dd forKey:typesKey];
        }
    }
    return dd;
}




/////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Implementation
/////////////////////////////////////////////////////////////////////////////////////


@implementation OHAttributedLabel

/////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Init/Dealloc
/////////////////////////////////////////////////////////////////////////////////////

- (void)commonInit
{
    _linkColor = MRC_RETAIN([UIColor blueColor]);
    _highlightedLinkColor = MRC_RETAIN([UIColor colorWithWhite:0.4f alpha:0.3f]);
	_linkUnderlineStyle = kCTUnderlineStyleSingle | kCTUnderlinePatternSolid;
    
    self.automaticallyAddLinksForType = 0;
	self.onlyCatchTouchesOnLinks = YES;
	self.userInteractionEnabled = YES;
	self.contentMode = UIViewContentModeRedraw;
	[self resetAttributedText];
    
    _gestureRecogniser = [[OHTouchesGestureRecognizer alloc] initWithTarget:self action:@selector(_gestureRecognised:)];
    _gestureRecogniser.delegate = self;
    [self addGestureRecognizer:_gestureRecogniser];
}

- (id) initWithFrame:(CGRect)aFrame
{
	self = [super initWithFrame:aFrame];
	if (self != nil)
    {
		[self commonInit];
	}
	return self;
}

- (id)initWithCoder:(NSCoder *)decoder
{
	self = [super initWithCoder:decoder];
	if (self != nil)
    {
		[self commonInit];
#if OHATTRIBUTEDLABEL_WARN_ABOUT_KNOWN_ISSUES
		[self warnAboutKnownIssues_CheckLineBreakMode_FromXIB:YES];
		[self warnAboutKnownIssues_CheckAdjustsFontSizeToFitWidth_FromXIB:YES];
#endif
	}
	return self;
}

-(void)dealloc
{
	[self resetTextFrame]; // CFRelease the text frame

#if ! __has_feature(objc_arc)
    [_linksDetector release]; _linksDetector = nil;
    [_linkColor release]; _linkColor = nil;
	[_highlightedLinkColor release]; _highlightedLinkColor = nil;
	[_activeLink release]; _activeLink = nil;

	[_attributedText release]; _attributedText = nil;
    [_attributedTextWithLinks release]; _attributedTextWithLinks = nil;
	[_customLinks release]; _customLinks = nil;
    
    [_gestureRecogniser release]; _gestureRecogniser = nil;

	[super dealloc];
#endif
}





/////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Links Managment
/////////////////////////////////////////////////////////////////////////////////////

-(void)addCustomLink:(NSURL*)linkUrl inRange:(NSRange)range
{
	NSTextCheckingResult* link = [NSTextCheckingResult linkCheckingResultWithRange:range URL:linkUrl];
	if (_customLinks == nil)
    {
		_customLinks = [[NSMutableArray alloc] init];
	}
	[_customLinks addObject:link];
    [self setNeedsRecomputeLinksInText];
	[self setNeedsDisplay];
}

-(void)removeAllCustomLinks
{
	[_customLinks removeAllObjects];
	[self setNeedsDisplay];
}

-(void)setNeedsRecomputeLinksInText
{
    _needsRecomputeLinksInText = YES;
    [self setNeedsDisplay];
}

-(void)recomputeLinksInTextIfNeeded
{
    if (!_needsRecomputeLinksInText)
    {
        return;
    }
    
    _needsRecomputeLinksInText = NO;
    
    __block BOOL hasOHLinkAttribute = NO;
    [_attributedText enumerateAttribute:kOHLinkAttributeName inRange:NSMakeRange(0, [_attributedText length])
                                options:0 usingBlock:^(id value, NSRange range, BOOL *stop)
     {
         if (value)
         {
             hasOHLinkAttribute = YES;
             *stop = YES;
         }
     }];
    
    if (!_attributedText || (self.automaticallyAddLinksForType == 0 && _customLinks.count == 0 && hasOHLinkAttribute == 0))
    {
        MRC_RELEASE(_attributedTextWithLinks);
        _attributedTextWithLinks = MRC_RETAIN(_attributedText);
        if (_measuringFramesetter) {
            CFRelease(_measuringFramesetter);
            _measuringFramesetter = nil;
        }
        return;
	}
    
    @autoreleasepool
    {
        NSMutableAttributedString* mutAS = [_attributedText mutableCopy];
        
        BOOL hasLinkColorSelector = [self.delegate respondsToSelector:@selector(attributedLabel:colorForLink:underlineStyle:)];
        
#if OHATTRIBUTEDLABEL_WARN_ABOUT_OLD_API
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            BOOL hasOldLinkColorSelector = [self.delegate respondsToSelector:@selector(colorForLink:underlineStyle:)];
            if (hasOldLinkColorSelector)
            {
                NSLog(@"[OHAttributedLabel] Warning: \"-colorForLink:underlineStyle:\" delegate method is deprecated and has been replaced"
                      "by \"-attributedLabel:colorForLink:underlineStyle:\" to be more compliant with naming conventions.");
            }
        });
#endif
        
        NSString* plainText = [_attributedText string];
        
        void (^applyLinkStyle)(NSTextCheckingResult*) = ^(NSTextCheckingResult* result)
        {
            int32_t uStyle = self.linkUnderlineStyle;
            UIColor* thisLinkColor = hasLinkColorSelector
            ? [self.delegate attributedLabel:self colorForLink:result underlineStyle:&uStyle]
            : self.linkColor;
            
            if (thisLinkColor)
            {
                [mutAS setTextColor:thisLinkColor range:[result range]];
            }
            if ((uStyle & 0xFFFF) != kCTUnderlineStyleNone)
            {
                [mutAS setTextUnderlineStyle:uStyle range:[result range]];
            }
            if (uStyle & kOHBoldStyleTraitMask)
            {
                [mutAS setTextBold:((uStyle & kOHBoldStyleTraitSetBold) == kOHBoldStyleTraitSetBold) range:[result range]];
            }
        };
        
        // Links set by text attribute
        [_attributedText enumerateAttribute:kOHLinkAttributeName inRange:NSMakeRange(0, [_attributedText length])
                                    options:0 usingBlock:^(id value, NSRange range, BOOL *stop)
         {
             if (value)
             {
                 NSTextCheckingResult* result = [NSTextCheckingResult linkCheckingResultWithRange:range URL:(NSURL*)value];
                 applyLinkStyle(result);
             }
         }];

        // Automatically Detected Links
        if (plainText && (self.automaticallyAddLinksForType > 0))
        {
            [_linksDetector enumerateMatchesInString:plainText options:0 range:NSMakeRange(0,[plainText length])
                                          usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop)
             {
                 applyLinkStyle(result);
             }];
        }
        
        // Custom Links
        [_customLinks enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop)
         {
             applyLinkStyle((NSTextCheckingResult*)obj);
         }];
        
        MRC_RELEASE(_attributedTextWithLinks);
        _attributedTextWithLinks = [[NSAttributedString alloc] initWithAttributedString:mutAS];
        if (_measuringFramesetter) {
            CFRelease(_measuringFramesetter);
            _measuringFramesetter = nil;
        }
        
        MRC_RELEASE(mutAS);
    } // @autoreleasepool
    
    [self setNeedsDisplay];
}

-(NSTextCheckingResult*)linkAtCharacterIndex:(CFIndex)idx
{
	__block NSTextCheckingResult* foundResult = nil;
	
    @autoreleasepool
    {
        NSString* plainText = [_attributedText string];
        
        // Links set by text attribute
        if (_attributedText)
        {
            [_attributedText enumerateAttribute:kOHLinkAttributeName inRange:NSMakeRange(0, [_attributedText length])
                                        options:0 usingBlock:^(id value, NSRange range, BOOL *stop)
             {
                 if (value && NSLocationInRange((NSUInteger)idx, range))
                 {
                     NSTextCheckingResult* result = [NSTextCheckingResult linkCheckingResultWithRange:range URL:(NSURL*)value];
                     foundResult = MRC_RETAIN(result);
                     *stop = YES;
                 }
             }];
        }
        
        if (!foundResult && plainText && (self.automaticallyAddLinksForType > 0))
        {
            // Automatically Detected Links
            [_linksDetector enumerateMatchesInString:plainText options:0 range:NSMakeRange(0,[plainText length])
                                          usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop)
             {
                 NSRange r = [result range];
                 if (NSLocationInRange((NSUInteger)idx, r))
                 {
                     foundResult = MRC_RETAIN(result);
                     *stop = YES;
                 }
             }];
        }
        
        if (!foundResult)
        {
            // Custom Links
            [_customLinks enumerateObjectsUsingBlock:^(id obj, NSUInteger aidx, BOOL *stop)
             {
                 NSRange r = [(NSTextCheckingResult*)obj range];
                 if (NSLocationInRange((NSUInteger)idx, r))
                 {
                     foundResult = MRC_RETAIN(obj);
                     *stop = YES;
                 }
             }];
        }
    } // @autoreleasepool
    
	return MRC_AUTORELEASE(foundResult);
}

-(NSTextCheckingResult*)linkAtPoint:(CGPoint)point
{
	static const CGFloat kVMargin = 5.f;
	if (!CGRectContainsPoint(CGRectInset(drawingRect, 0, -kVMargin), point))
    {
        return nil;
    }
	
	CFArrayRef lines = CTFrameGetLines(textFrame);
	if (!lines)
    {
        return nil;
    }
	CFIndex nbLines = CFArrayGetCount(lines);
	NSTextCheckingResult* link = nil;
	
	CGPoint origins[nbLines];
	CTFrameGetLineOrigins(textFrame, CFRangeMake(0,0), origins);
	
	for (int lineIndex=0 ; lineIndex<nbLines ; ++lineIndex)
    {
		// this actually the origin of the line rect, so we need the whole rect to flip it
		CGPoint lineOriginFlipped = origins[lineIndex];
		
		CTLineRef line = CFArrayGetValueAtIndex(lines, lineIndex);
		CGRect lineRectFlipped = CTLineGetTypographicBoundsAsRect(line, lineOriginFlipped);
		CGRect lineRect = CGRectFlipped(lineRectFlipped, CGRectFlipped(drawingRect,self.bounds));
		
		lineRect = CGRectInset(lineRect, 0, -kVMargin);
		if (CGRectContainsPoint(lineRect, point))
        {
			CGPoint relativePoint = CGPointMake(point.x-CGRectGetMinX(lineRect),
												point.y-CGRectGetMinY(lineRect));
			CFIndex idx = CTLineGetStringIndexForPosition(line, relativePoint);
            if ((relativePoint.x < CTLineGetOffsetForStringIndex(line, idx, NULL)) && (idx>0))
            {
                // CTLineGetStringIndexForPosition compute the *carret* position, not the character under the CGPoint. So if the index
                // returned correspond to the character *after* the tapped point, because we tapped on the right half of the character,
                // then substract 1 to the index to get to the real tapped character index.
                --idx;
            }
            
			link = ([self linkAtCharacterIndex:idx]);
			if (link)
            {
                return link;
            }
		}
	}
	return nil;
}

-(UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
	// never return self. always return the result of [super hitTest..].
	// this takes userInteraction state, enabled, alpha values etc. into account
	UIView *hitResult = [super hitTest:point withEvent:event];
	
	// don't check for links if the event was handled by one of the subviews
	if (hitResult != self)
    {
		return hitResult;
	}
	
	if (self.onlyCatchTouchesOnLinks)
    {
		BOOL didHitLink = ([self linkAtPoint:point] != nil);
		if (!didHitLink)
        {
			// not catch the touch if it didn't hit a link
			return nil;
		}
	}
	return hitResult;
}

-(void)_gestureRecognised:(UIGestureRecognizer*)recogniser
{
    CGPoint pt = [recogniser locationInView:self];
    
    switch (recogniser.state) {
        case UIGestureRecognizerStateBegan: {
            self.activeLink = [self linkAtPoint:pt];
            _touchStartPoint = pt;
            
            if (_catchTouchesOnLinksOnTouchBegan)
            {
                [self processActiveLink];
            }
            
            // we're using activeLink to draw a highlight in -drawRect:
            [self setNeedsDisplay];
        }
            break;
        case UIGestureRecognizerStateEnded: {
            if (!_catchTouchesOnLinksOnTouchBegan)
            {
                // Check that the link on touchEnd is the same as the link on touchBegan
                NSTextCheckingResult* linkAtTouchesEnded = [self linkAtPoint:pt];
                BOOL closeToStart = (fabs(_touchStartPoint.x - pt.x) < 10 && fabs(_touchStartPoint.y - pt.y) < 10);
                
                // we must check on equality of the ranges themselves since the data detectors create new results
                if (_activeLink && (NSEqualRanges(_activeLink.range,linkAtTouchesEnded.range) || closeToStart))
                {
                    // Same link on touchEnded than the one on touchBegan, so trigger it
                    [self processActiveLink];
                }
            }
            
            self.activeLink = nil;
            [self setNeedsDisplay];
        }
            break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            self.activeLink = nil;
            [self setNeedsDisplay];
        }
            break;
        case UIGestureRecognizerStateChanged:
        case UIGestureRecognizerStatePossible:
            break;
    }
}

- (void)processActiveLink
{
    NSTextCheckingResult* linkToOpen = _activeLink;
    // In case the delegate calls recomputeLinksInText or anything that will clear the _activeLink variable, keep it around anyway
    (void)MRC_AUTORELEASE(MRC_RETAIN(linkToOpen));
    
    BOOL openLink = (self.delegate && [self.delegate respondsToSelector:@selector(attributedLabel:shouldFollowLink:)])
    ? [self.delegate attributedLabel:self shouldFollowLink:linkToOpen] : YES;
    
    if (openLink)
    {
        [[UIApplication sharedApplication] openURL:linkToOpen.extendedURL];
    }
}




/////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Drawing Text
/////////////////////////////////////////////////////////////////////////////////////

-(void)resetTextFrame
{
	if (textFrame)
    {
		CFRelease(textFrame);
		textFrame = NULL;
	}
}

- (void)drawTextInRect:(CGRect)aRect
{
	if (_attributedText)
    {
        @autoreleasepool
        {
            CGContextRef ctx = UIGraphicsGetCurrentContext();
            CGContextSaveGState(ctx);
            
            // flipping the context to draw core text
            // no need to flip our typographical bounds from now on
            CGContextConcatCTM(ctx, CGAffineTransformScale(CGAffineTransformMakeTranslation(0, self.bounds.size.height), 1.f, -1.f));
            
            if (self.shadowColor)
            {
                CGContextSetShadowWithColor(ctx, self.shadowOffset, 0.0, self.shadowColor.CGColor);
            }
            
            [self recomputeLinksInTextIfNeeded];
            NSAttributedString* attributedStringToDisplay = _attributedTextWithLinks;
            if (self.highlighted && self.highlightedTextColor != nil)
            {
                NSMutableAttributedString* mutAS = [attributedStringToDisplay mutableCopy];
                [mutAS setTextColor:self.highlightedTextColor];
                attributedStringToDisplay = mutAS;
                (void)MRC_AUTORELEASE(mutAS);
            }
            if (textFrame == NULL)
            {
                CFAttributedStringRef cfAttrStrWithLinks = (BRIDGE_CAST CFAttributedStringRef)attributedStringToDisplay;
                CTFramesetterRef framesetter = CTFramesetterCreateWithAttributedString(cfAttrStrWithLinks);
                drawingRect = self.bounds;
                if (self.centerVertically || self.extendBottomToFit)
                {
                    CGSize sz = CTFramesetterSuggestFrameSizeWithConstraints(framesetter,CFRangeMake(0,0),NULL,CGSizeMake(drawingRect.size.width,CGFLOAT_MAX),NULL);
                    if (self.extendBottomToFit)
                    {
                        CGFloat delta = MAX(0.f , ceilf(sz.height - drawingRect.size.height)) + 10 /* Security margin */;
                        drawingRect.origin.y -= delta;
                        drawingRect.size.height += delta;
                    }
                    if (self.centerVertically && drawingRect.size.height > sz.height)
                    {
                        drawingRect.origin.y -= (drawingRect.size.height - sz.height)/2;
                    }
                }
                CGMutablePathRef path = CGPathCreateMutable();
                CGPathAddRect(path, NULL, drawingRect);
                textFrame = CTFramesetterCreateFrame(framesetter,CFRangeMake(0,0), path, NULL);
                CGPathRelease(path);
                CFRelease(framesetter);
            }
            
            // draw highlights for activeLink
            if (_activeLink)
            {
                [self drawActiveLinkHighlightForRect:drawingRect];
            }
            
            // XXX: Start of code snipped from TTTAttributedLabel
            CFArrayRef lines = CTFrameGetLines(textFrame);
            NSInteger numberOfLines = self.numberOfLines > 0 ? MIN(self.numberOfLines, CFArrayGetCount(lines)) : CFArrayGetCount(lines);
            BOOL truncateLastLine = (self.lineBreakMode == UILineBreakModeHeadTruncation || self.lineBreakMode == UILineBreakModeMiddleTruncation || self.lineBreakMode == UILineBreakModeTailTruncation);
            
            CGPoint lineOrigins[numberOfLines];
            CTFrameGetLineOrigins(textFrame, CFRangeMake(0, numberOfLines), lineOrigins);
            
            for (CFIndex lineIndex = 0; lineIndex < numberOfLines; lineIndex++) {
                CGPoint lineOrigin = lineOrigins[lineIndex];
                CGContextSetTextPosition(ctx, lineOrigin.x, lineOrigin.y);
                CTLineRef line = CFArrayGetValueAtIndex(lines, lineIndex);
                
                if (lineIndex == numberOfLines - 1 && truncateLastLine) {
                    CFRange lastLineRange = CTLineGetStringRange(line);
                    
                    if (!(lastLineRange.length == 0 && lastLineRange.location == 0) && lastLineRange.location + lastLineRange.length < (long)_attributedText.length) {
                        CTLineTruncationType truncationType;
                        NSUInteger truncationAttributePosition = (NSUInteger)lastLineRange.location;
                        NSUILineBreakMode lineBreakMode = self.lineBreakMode;
                        
                        // Multiple lines, only use UILineBreakModeTailTruncation. It's hard to do head and middle, so just do tail for now.
                        if (numberOfLines != 1) {
                            lineBreakMode = (NSUILineBreakMode)UILineBreakModeTailTruncation;
                        }
                        
                        switch (lineBreakMode) {
                            case UILineBreakModeHeadTruncation:
                                truncationType = kCTLineTruncationStart;
                                break;
                            case UILineBreakModeMiddleTruncation:
                                truncationType = kCTLineTruncationMiddle;
                                truncationAttributePosition += (NSUInteger)(lastLineRange.length / 2);
                                break;
                            case UILineBreakModeTailTruncation:
                            default:
                                truncationType = kCTLineTruncationEnd;
                                truncationAttributePosition += (NSUInteger)(lastLineRange.length - 1);
                                break;
                        }
                        
                        NSDictionary *tokenAttributes = [_attributedText attributesAtIndex:truncationAttributePosition effectiveRange:NULL];
                        NSString *truncationTokenString = @"\u2026";
                        NSAttributedString *attributedTokenString = [[NSAttributedString alloc] initWithString:truncationTokenString attributes:tokenAttributes];
                        CTLineRef truncationToken = CTLineCreateWithAttributedString((CFAttributedStringRef)attributedTokenString);
                        
                        // Append truncationToken to the string
                        // because if string isn't too long, CT wont add the truncationToken on it's own
                        // There is no change of a double truncationToken because CT only add the token if it removes characters (and the one we add will go first)
                        NSMutableAttributedString *truncationString = [[_attributedText attributedSubstringFromRange:NSMakeRange((NSUInteger)lastLineRange.location, (NSUInteger)lastLineRange.length)] mutableCopy];
                        if (lastLineRange.length > 0) {
                            // Remove any newline at the end (we don't want newline space between the text and the truncation token). There can only be one, because the second would be on the next line.
                            unichar lastCharacter = [[truncationString string] characterAtIndex:(NSUInteger)lastLineRange.length - 1];
                            if ([[NSCharacterSet newlineCharacterSet] characterIsMember:lastCharacter]) {
                                [truncationString deleteCharactersInRange:NSMakeRange((NSUInteger)lastLineRange.length - 1, 1)];
                            }
                        }
                        [truncationString appendAttributedString:attributedTokenString];
                        CTLineRef truncationLine = CTLineCreateWithAttributedString((CFAttributedStringRef)truncationString);
                        
                        // Truncate the line in case it is too long.
                        CTLineRef truncatedLine = CTLineCreateTruncatedLine(truncationLine, aRect.size.width, truncationType, truncationToken);
                        if (!truncatedLine) {
                            // If the line is not as wide as the truncationToken, truncatedLine is NULL
                            truncatedLine = CFRetain(truncationToken);
                        }
                        
                        // Adjust pen offset for flush depending on text alignment
                        CGFloat flushFactor = 0.0f;
                        switch (self.textAlignment) {
                            case UITextAlignmentCenter:
                                flushFactor = 0.5f;
                                break;
                            case UITextAlignmentRight:
                                flushFactor = 1.0f;
                                break;
                            case UITextAlignmentLeft:
                            default:
                                break;
                        }
                        
                        CGFloat penOffset = (CGFloat)CTLineGetPenOffsetForFlush(truncatedLine, flushFactor, aRect.size.width);
                        CGContextSetTextPosition(ctx, penOffset, lineOrigin.y);
                        
                        CTLineDraw(truncatedLine, ctx);
                        
                        CFRelease(truncatedLine);
                        CFRelease(truncationLine);
                        CFRelease(truncationToken);
                        [attributedTokenString release];
                        [truncationString release];
                    } else {
                        CTLineDraw(line, ctx);
                    }
                } else {
                    CTLineDraw(line, ctx);
                }
            }
            // XXX: End of code snipped from TTTAttributedLabel
            
            CGContextRestoreGState(ctx);
        } // @autoreleasepool
	} else {
		[super drawTextInRect:aRect];
	}
}

-(void)drawActiveLinkHighlightForRect:(CGRect)rect
{
    if (!self.highlightedLinkColor)
    {
        return;
    }
    
	CGContextRef ctx = UIGraphicsGetCurrentContext();
	CGContextSaveGState(ctx);
	CGContextConcatCTM(ctx, CGAffineTransformMakeTranslation(rect.origin.x, rect.origin.y));
	[self.highlightedLinkColor setFill];
	
	NSRange activeLinkRange = _activeLink.range;
	
	CFArrayRef lines = CTFrameGetLines(textFrame);
	CFIndex lineCount = CFArrayGetCount(lines);
	CGPoint lineOrigins[lineCount];
	CTFrameGetLineOrigins(textFrame, CFRangeMake(0,0), lineOrigins);
	for (CFIndex lineIndex = 0; lineIndex < lineCount; lineIndex++)
    {
		CTLineRef line = CFArrayGetValueAtIndex(lines, lineIndex);
		
		if (!CTLineContainsCharactersFromStringRange(line, activeLinkRange))
        {
			continue; // with next line
		}
		
		// we use this rect to union the bounds of successive runs that belong to the same active link
		CGRect unionRect = CGRectZero;
		
		CFArrayRef runs = CTLineGetGlyphRuns(line);
		CFIndex runCount = CFArrayGetCount(runs);
		for (CFIndex runIndex = 0; runIndex < runCount; runIndex++)
        {
			CTRunRef run = CFArrayGetValueAtIndex(runs, runIndex);
			
			if (!CTRunContainsCharactersFromStringRange(run, activeLinkRange))
            {
				if (!CGRectIsEmpty(unionRect))
                {
					CGContextFillRect(ctx, unionRect);
					unionRect = CGRectZero;
				}
				continue; // with next run
			}
            
            CFRange fullRunRange = CTRunGetStringRange(run);

            CFIndex startActiveLinkInRun = (CFIndex)activeLinkRange.location - fullRunRange.location;
            CFIndex endActiveLinkInRun = startActiveLinkInRun + (CFIndex)activeLinkRange.length;
            
            CFRange inRunRange;
            inRunRange.location = MAX(startActiveLinkInRun, 0);
            inRunRange.length = MIN(endActiveLinkInRun, fullRunRange.length);
            
            CGRect linkRunRect = CTRunGetTypographicBoundsForRangeAsRect(run, line, lineOrigins[lineIndex], inRunRange, ctx);
            
			linkRunRect = CGRectIntegral(linkRunRect);		// putting the rect on pixel edges
			linkRunRect = CGRectInset(linkRunRect, -1, -1);	// increase the rect a little
			if (CGRectIsEmpty(unionRect))
            {
				unionRect = linkRunRect;
			} else {
				unionRect = CGRectUnion(unionRect, linkRunRect);
			}
		}
		if (!CGRectIsEmpty(unionRect))
        {
			CGContextFillRect(ctx, unionRect);
			//unionRect = CGRectZero;
		}
	}
	CGContextRestoreGState(ctx);
}

- (CGSize)sizeThatFits:(CGSize)size
{
    if (size.width == 0.0f) {
        return CGSizeZero;
    } else {
        [self recomputeLinksInTextIfNeeded];
        if (_attributedTextWithLinks) {
            if (!_measuringFramesetter) {
                _measuringFramesetter = CTFramesetterCreateWithAttributedString((BRIDGE_CAST CFAttributedStringRef)_attributedTextWithLinks);
            }
            
            CGSize returnSize = [_attributedTextWithLinks sizeConstrainedToSize:size maxLines:self.numberOfLines fitRange:NULL framesetter:_measuringFramesetter];
            return returnSize;
        } else {
            return CGSizeZero;
        }
    }
}





/////////////////////////////////////////////////////////////////////////////////////
#pragma mark - UIGestureRecognizerDelegate
/////////////////////////////////////////////////////////////////////////////////////

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return ([[otherGestureRecognizer.view class] isSubclassOfClass:[UIScrollView class]]);
}





/////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Setters/Getters
/////////////////////////////////////////////////////////////////////////////////////

// Note: Even if we now have auto property synthesis, we still write the @synthesize here for older compilers compatibility
@synthesize activeLink = _activeLink;
@synthesize linkColor = _linkColor;
@synthesize highlightedLinkColor = _highlightedLinkColor;
@synthesize linkUnderlineStyle = _linkUnderlineStyle;
@synthesize centerVertically = _centerVertically;
@synthesize automaticallyAddLinksForType = _automaticallyAddLinksForType;
@synthesize onlyCatchTouchesOnLinks = _onlyCatchTouchesOnLinks;
@synthesize catchTouchesOnLinksOnTouchBegan = _catchTouchesOnLinksOnTouchBegan;
@synthesize extendBottomToFit = _extendBottomToFit;
@synthesize delegate = _delegate;


-(void)resetAttributedText
{
	NSMutableAttributedString* mutAttrStr = [NSMutableAttributedString attributedStringWithString:self.text];
	if (self.font)
    {
        [mutAttrStr setFont:self.font];
    }
	if (self.textColor)
    {
        [mutAttrStr setTextColor:self.textColor];
    }
	CTTextAlignment coreTextAlign = CTTextAlignmentFromUITextAlignment(self.textAlignment);
	CTLineBreakMode coreTextLBMode = CTLineBreakModeFromUILineBreakMode(self.lineBreakMode);
	[mutAttrStr setTextAlignment:coreTextAlign lineBreakMode:coreTextLBMode];
    
	self.attributedText = [NSAttributedString attributedStringWithAttributedString:mutAttrStr];
}

-(NSAttributedString*)attributedText
{
	if (!_attributedText)
    {
		[self resetAttributedText];
	}
    return _attributedText;
}

-(void)setAttributedText:(NSAttributedString*)newText
{
	MRC_RELEASE(_attributedText);
	_attributedText = [newText copy];
	[super setText:newText.string];
	[self setAccessibilityLabel:_attributedText.string];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	[self removeAllCustomLinks];
#pragma clang diagnostic pop
    [self setNeedsRecomputeLinksInText];
}


/////////////////////////////////////////////////////////////////////////////////////

-(void)setText:(NSString *)text
{
	NSString* cleanedText = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
							 stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	[super setText:cleanedText]; // will call setNeedsDisplay too
	[self resetAttributedText];
}

-(void)setFont:(UIFont *)font
{
    if (_attributedText)
    {
        NSMutableAttributedString* mutAS = [NSMutableAttributedString attributedStringWithAttributedString:_attributedText];
        [mutAS setFont:font];
        MRC_RELEASE(_attributedText);
        _attributedText = [[NSAttributedString alloc] initWithAttributedString:mutAS];
    }
	[super setFont:font]; // will call setNeedsDisplay too
}

-(void)setTextColor:(UIColor *)color
{
    if (_attributedText)
    {
        NSMutableAttributedString* mutAS = [NSMutableAttributedString attributedStringWithAttributedString:_attributedText];
        [mutAS setTextColor:color];
        MRC_RELEASE(_attributedText);
        _attributedText = [[NSAttributedString alloc] initWithAttributedString:mutAS];
    }
	[super setTextColor:color]; // will call setNeedsDisplay too
}

-(void)setTextAlignment:(NSUITextAlignment)alignment
{
    if (_attributedText)
    {
        CTTextAlignment coreTextAlign = CTTextAlignmentFromUITextAlignment(alignment);
        CTLineBreakMode coreTextLBMode = CTLineBreakModeFromUILineBreakMode(self.lineBreakMode);
        NSMutableAttributedString* mutAS = [NSMutableAttributedString attributedStringWithAttributedString:_attributedText];
        [mutAS setTextAlignment:coreTextAlign lineBreakMode:coreTextLBMode];
        MRC_RELEASE(_attributedText);
        _attributedText = [[NSAttributedString alloc] initWithAttributedString:mutAS];
    }
	[super setTextAlignment:alignment]; // will call setNeedsDisplay too
}

-(void)setLineBreakMode:(NSUILineBreakMode)lineBreakMode
{
    if (_attributedText)
    {
        CTTextAlignment coreTextAlign = CTTextAlignmentFromUITextAlignment(self.textAlignment);
        CTLineBreakMode coreTextLBMode = CTLineBreakModeFromUILineBreakMode(lineBreakMode);
        NSMutableAttributedString* mutAS = [NSMutableAttributedString attributedStringWithAttributedString:_attributedText];
        [mutAS setTextAlignment:coreTextAlign lineBreakMode:coreTextLBMode];
        MRC_RELEASE(_attributedText);
        _attributedText = [[NSAttributedString alloc] initWithAttributedString:mutAS];
    }
	[super setLineBreakMode:lineBreakMode]; // will call setNeedsDisplay too
	
#if OHATTRIBUTEDLABEL_WARN_ABOUT_KNOWN_ISSUES
	[self warnAboutKnownIssues_CheckLineBreakMode_FromXIB:NO];
#endif	
}

-(void)setNumberOfLines:(NSInteger)numberOfLines
{
    [super setNumberOfLines:numberOfLines];
    
#if OHATTRIBUTEDLABEL_WARN_ABOUT_KNOWN_ISSUES
    [self warnAboutKnownIssues_CheckLineBreakMode_FromXIB:NO];
#endif
}

-(void)setCenterVertically:(BOOL)val
{
	_centerVertically = val;
	[self setNeedsDisplay];
}

-(void)setAutomaticallyAddLinksForType:(NSTextCheckingTypes)types
{
	_automaticallyAddLinksForType = types;

    NSDataDetector* dd = sharedReusableDataDetector(types);
    MRC_RELEASE(_linksDetector);
    _linksDetector = MRC_RETAIN(dd);
    [self setNeedsRecomputeLinksInText];
}
-(NSDataDetector*)linksDataDetector
{
    return _linksDetector;
}

-(void)setLinkColor:(UIColor *)newLinkColor
{
    MRC_RELEASE(_linkColor);
    _linkColor = MRC_RETAIN(newLinkColor);
    
    [self setNeedsRecomputeLinksInText];
}

-(void)setLinkUnderlineStyle:(int32_t)newValue
{
    _linkUnderlineStyle = newValue;
    [self setNeedsRecomputeLinksInText];
}

-(void)setUnderlineLinks:(BOOL)newValue
{
    self.linkUnderlineStyle = (self.linkUnderlineStyle & ~0xFF) | ((newValue ? kCTUnderlineStyleSingle : kCTUnderlineStyleNone) & 0xFF);
}

-(void)setExtendBottomToFit:(BOOL)val
{
	_extendBottomToFit = val;
	[self setNeedsDisplay];
}

-(void)setNeedsDisplay
{
	[self resetTextFrame];
	[super setNeedsDisplay];
}




/////////////////////////////////////////////////////////////////////////////////////
#pragma mark - UILabel unsupported features/known issues warnings
/////////////////////////////////////////////////////////////////////////////////////

#if OHATTRIBUTEDLABEL_WARN_ABOUT_KNOWN_ISSUES
-(void)warnAboutKnownIssues_CheckLineBreakMode_FromXIB:(BOOL)fromXIB
{
#if __IPHONE_OS_VERSION_MAX_ALLOWED < 60000
	BOOL truncationMode = self.numberOfLines != 1 && ((self.lineBreakMode == UILineBreakModeHeadTruncation)
	|| (self.lineBreakMode == UILineBreakModeMiddleTruncation));
#else
	BOOL truncationMode = self.numberOfLines != 1 && ((self.lineBreakMode == NSLineBreakByTruncatingHead)
	|| (self.lineBreakMode == NSLineBreakByTruncatingMiddle));
#endif
	if (truncationMode)
    {
		NSLog(@"[OHAttributedLabel] Warning: \"UILineBreakMode(Middle|Head)Truncation\" lineBreakModes are not yet supported when numberOfLines != 1"
              "See https://github.com/AliSoftware/OHAttributedLabel/issues/3");
        if (fromXIB)
        {
            NSLog(@"  (To avoid this warning, change this property in your XIB file to another lineBreakMode value)");
        }
	}
}

-(void)warnAboutKnownIssues_CheckAdjustsFontSizeToFitWidth_FromXIB:(BOOL)fromXIB
{
	if (self.adjustsFontSizeToFitWidth)
    {
		NSLog(@"[OHAttributedLabel] Warning: the \"adjustsFontSizeToFitWidth\" property is not supported by CoreText. "
              "It will be ignored by OHAttributedLabel.");
        if (fromXIB)
        {
            NSLog(@"  (To avoid this warning, uncheck the 'Autoshrink' property in your XIB file)");
        }

	}
}

-(void)setAdjustsFontSizeToFitWidth:(BOOL)value
{
	[super setAdjustsFontSizeToFitWidth:value];
	[self warnAboutKnownIssues_CheckAdjustsFontSizeToFitWidth_FromXIB:NO];
}
#endif

@end
