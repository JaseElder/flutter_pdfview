// Copyright 2018 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#import "FlutterPDFView.h"

@implementation FLTPDFViewFactory {
    NSObject<FlutterBinaryMessenger>* _messenger;
}

- (instancetype)initWithMessenger:(NSObject<FlutterBinaryMessenger>*)messenger {
    self = [super init];
    if (self) {
        _messenger = messenger;
    }
    return self;
}

- (NSObject<FlutterMessageCodec>*)createArgsCodec {
    return [FlutterStandardMessageCodec sharedInstance];
}

- (NSObject<FlutterPlatformView>*)createWithFrame:(CGRect)frame
                                   viewIdentifier:(int64_t)viewId
                                        arguments:(id _Nullable)args {
    FLTPDFViewController* pdfviewController = [[FLTPDFViewController alloc] initWithFrame:frame
                                                                           viewIdentifier:viewId
                                                                                arguments:args
                                                                          binaryMessenger:_messenger];
    return pdfviewController;
}

@end

@implementation FLTPDFViewController {
    FLTPDFView* _pdfView;
    int64_t _viewId;
    FlutterMethodChannel* _channel;
}

- (instancetype)initWithFrame:(CGRect)frame
               viewIdentifier:(int64_t)viewId
                    arguments:(id _Nullable)args
              binaryMessenger:(NSObject<FlutterBinaryMessenger>*)messenger {
    self = [super init];
    _pdfView = [[FLTPDFView new] initWithFrame:frame arguments:args controller:self];
    _viewId = viewId;

    @try  {
        NSString* hexBackgroundColor = args[@"hexBackgroundColor"];
        unsigned rgbValue = 0;
        NSScanner *scanner = [NSScanner scannerWithString:hexBackgroundColor];
        [scanner setScanLocation:1]; // bypass '#' character
        [scanner scanHexInt:&rgbValue];

        UIColor *colour = [UIColor colorWithRed:((rgbValue & 0xFF0000) >> 16)/255.0
                                          green:((rgbValue & 0xFF00) >> 8)/255.0 blue:(rgbValue & 0xFF)/255.0 alpha:1.0];
        _pdfView.view.backgroundColor = colour;
    } @catch (NSException *exception) {
    }

    NSString* channelName = [NSString stringWithFormat:@"plugins.endigo.io/pdfview_%lld", viewId];
    _channel = [FlutterMethodChannel methodChannelWithName:channelName binaryMessenger:messenger];
    __weak __typeof__(self) weakSelf = self;
    [_channel setMethodCallHandler:^(FlutterMethodCall* call, FlutterResult result) {
        [weakSelf onMethodCall:call result:result];
    }];

    return self;
}

- (void)onMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    if ([[call method] isEqualToString:@"pageCount"]) {
        [_pdfView getPageCount:call result:result];
    } else if ([[call method] isEqualToString:@"currentPageSize"]) {
        [_pdfView getCurrentPageSize:call result:result];
    } else if ([[call method] isEqualToString:@"getPosition"]) {
        [_pdfView getPosition:call result:result];
    } else if ([[call method] isEqualToString:@"getScale"]) {
        [_pdfView getScale:call result:result];
    } else if ([[call method] isEqualToString:@"setPosition"]) {
        [_pdfView setPosition:call result:result];
    } else if ([[call method] isEqualToString:@"setScale"]) {
        [_pdfView setScale:call result:result];
    } else if ([[call method] isEqualToString:@"currentPage"]) {
        [_pdfView getCurrentPage:call result:result];
    } else if ([[call method] isEqualToString:@"setPage"]) {
        [_pdfView setPage:call result:result];
    } else if ([[call method] isEqualToString:@"updateSettings"]) {
        [_pdfView onUpdateSettings:call result:result];
    } else if ([[call method] isEqualToString:@"setZoomLimits"]) {
        [_pdfView setZoomLimits:call];
    } else {
        result(FlutterMethodNotImplemented);
    }
}

- (void)invokeChannelMethod:(NSString *)name arguments:(id)args {
    [_channel invokeMethod:name arguments:args];
}

- (UIView*)view {
    return _pdfView;
}

@end

@implementation FLTPDFView {
    FLTPDFViewController* _controller;
    PDFView* _pdfView;
    UIScrollView* _scrollView;
    NSNumber* _pageCount;
    NSNumber* _currentPage;
    PDFDestination* _currentDestination;
    BOOL _preventLinkNavigation;
    BOOL _autoSpacing;
    PDFPage* _defaultPage;
    BOOL _defaultPageSet;
    CGFloat _screenScale;
    CGRect _pageSpaceRect;
    CGFloat _pageSpaceRectWidth;
    CGFloat _pageSpaceRectHeight;
    CGFloat _scaleRatio;
    CGFloat _documentHeight;
}

- (instancetype)initWithFrame:(CGRect)frame
                    arguments:(id _Nullable)args
                   controller:(nonnull FLTPDFViewController *)controller {
    if ([super init]) {
        _controller = controller;
        _screenScale = [[UIScreen mainScreen] scale];

        _pdfView = [[PDFView alloc] initWithFrame: frame];
        _pdfView.delegate = self;
                
        _autoSpacing = [args[@"autoSpacing"] boolValue];
        BOOL pageFling = [args[@"pageFling"] boolValue];
        BOOL enableSwipe = [args[@"enableSwipe"] boolValue];
        _preventLinkNavigation = [args[@"preventLinkNavigation"] boolValue];
        
        NSInteger defaultPage = [args[@"defaultPage"] integerValue];

        NSString* filePath = args[@"filePath"];
        FlutterStandardTypedData* pdfData = args[@"pdfData"];

        PDFDocument* document;
        if ([filePath isKindOfClass:[NSString class]]) {
            NSURL* sourcePDFUrl = [NSURL fileURLWithPath:filePath];
            document = [[PDFDocument alloc] initWithURL: sourcePDFUrl];
        } else if ([pdfData isKindOfClass:[FlutterStandardTypedData class]]) {
            NSData* sourcePDFdata = [pdfData data];
            document = [[PDFDocument alloc] initWithData: sourcePDFdata];
        }


        if (document == nil) {
            [_controller invokeChannelMethod:@"onError" arguments:@{@"error" : @"cannot create document: File not in PDF format or corrupted."}];
        } else {
            _pdfView.autoresizesSubviews = true;
            _pdfView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            _pdfView.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1.0];

            BOOL swipeHorizontal = [args[@"swipeHorizontal"] boolValue];
            if (swipeHorizontal) {
                _pdfView.displayDirection = kPDFDisplayDirectionHorizontal;
            } else {
                _pdfView.displayDirection = kPDFDisplayDirectionVertical;
            }

            _pdfView.autoScales = _autoSpacing;
  
            [_pdfView usePageViewController:pageFling withViewOptions:nil];
            _pdfView.displayMode = enableSwipe ? kPDFDisplaySinglePageContinuous : kPDFDisplaySinglePage;
            _pdfView.displaysPageBreaks = NO;
            _pdfView.document = document;

            _pdfView.maxScaleFactor = 4.0;
            _pdfView.minScaleFactor = _pdfView.scaleFactorForSizeToFit;
               
            NSString* password = args[@"password"];
            if ([password isKindOfClass:[NSString class]] && [_pdfView.document isEncrypted]) {
                [_pdfView.document unlockWithPassword:password];
            }

            UITapGestureRecognizer *tapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onDoubleTap:)];
            tapGestureRecognizer.numberOfTapsRequired = 2;
            tapGestureRecognizer.numberOfTouchesRequired = 1;
            [_pdfView addGestureRecognizer:tapGestureRecognizer];

            NSUInteger pageCount = [document pageCount];

            if (pageCount <= defaultPage) {
                defaultPage = pageCount - 1;
            }

            _defaultPage = [document pageAtIndex: defaultPage];
            if (@available(iOS 11.0, *)) {
                for (id subview in _pdfView.subviews) {
                    if ([subview isKindOfClass: [UIScrollView class]]) {
                        _scrollView = subview;
                    }
                }
                
                _scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
                if (@available(iOS 13.0, *)) {
                    _scrollView.automaticallyAdjustsScrollIndicatorInsets = NO;
                }
            }
            
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handlePageChanged:) name:PDFViewPageChangedNotification object:_pdfView];
            [self addSubview:_pdfView];
        }
    }
    return self;
}

- (void)dealloc {
    [self stopObserving];
}

- (void)startObserving {
    if (_scrollView) {
        [_scrollView addObserver:self
                      forKeyPath:@"contentOffset"
                         options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld
                         context:nil];
    }
}

- (void)stopObserving {
    if (_scrollView) {
        [_scrollView removeObserver:self forKeyPath:@"contentOffset"];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context {
    if ([keyPath isEqualToString:@"contentOffset"]) {
        CGPoint newOffset = [change[NSKeyValueChangeNewKey] CGPointValue];
        CGPoint oldOffset = [change[NSKeyValueChangeOldKey] CGPointValue];
        if (!CGPointEqualToPoint(newOffset, oldOffset)) {
            __weak __typeof__(self) weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf handleOnDraw];
            });
        }
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _pdfView.frame = self.frame;
    _pdfView.minScaleFactor = _pdfView.scaleFactorForSizeToFit;
    _pdfView.maxScaleFactor = 4.0;
    if (_autoSpacing) {
        _pdfView.scaleFactor = _pdfView.scaleFactorForSizeToFit;
    }
    
    if (!_defaultPageSet && _defaultPage != nil) {
        [_pdfView goToPage: _defaultPage];
        _defaultPageSet = true;
    }
    
    _pageSpaceRect = [_pdfView convertRect:_pdfView.bounds toPage:_pdfView.currentPage];
    _pageSpaceRectWidth = _pageSpaceRect.size.width;
    _pageSpaceRectHeight = _pageSpaceRect.size.height;
    _scaleRatio = _screenScale * ((_pdfView.scaleFactorForSizeToFit == 0.0) ? 1.0 : _pdfView.scaleFactorForSizeToFit);
    _pageCount = [NSNumber numberWithUnsignedLong: _pdfView.document.pageCount];
    NSNumber* pc = _pageCount;
    _documentHeight = _pdfView.documentView.bounds.size.height;
    __weak __typeof__(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf handleRenderCompleted:pc];
    });
}

- (UIView*)view {
    return _pdfView;
}


- (void)getPageCount:(FlutterMethodCall*)call result:(FlutterResult)result {
    result(_pageCount);
}

- (void)getCurrentPageSize:(FlutterMethodCall*)call result:(FlutterResult)result {
    CGRect bounds = [_pdfView.currentPage boundsForBox:kPDFDisplayBoxMediaBox];
    NSArray *size = @[[NSNumber numberWithFloat:bounds.size.width], [NSNumber numberWithFloat:bounds.size.height]];
    result(size);
}

- (void)getPosition:(FlutterMethodCall*)call result:(FlutterResult)result {
    PDFPage* currentPage = _pdfView.currentPage;
    int pageNo = (int)[_pdfView.document indexForPage:currentPage] + 1;
    float currentPageHeight = [currentPage boundsForBox:kPDFDisplayBoxMediaBox].size.height;
    _pageSpaceRect = [_pdfView convertRect:_pdfView.frame toPage:currentPage];
    float flutterNormalisedY = (_pageSpaceRect.origin.y + _pageSpaceRectHeight + ((_pageCount.intValue - pageNo) * currentPageHeight) - _documentHeight) * _scaleRatio;
    
    NSArray *position = @[[NSNumber numberWithFloat:MAX(_pageSpaceRect.origin.x, 0)], [NSNumber numberWithFloat:flutterNormalisedY]];
    result(position);
}

- (void)getScale:(FlutterMethodCall*)call result:(FlutterResult)result {
    NSNumber *scale = [NSNumber numberWithFloat:_pdfView.scaleFactor];
    result(scale);
}

- (void)setPosition:(FlutterMethodCall*)call result:(FlutterResult)result {
    NSDictionary<NSString*, NSNumber*>* arguments = [call arguments];
    float xPos = arguments[@"xPos"].floatValue;
    float yPos = arguments[@"yPos"].floatValue;
    PDFPage* currentPage = _pdfView.currentPage;
    _scaleRatio = _screenScale * ((_pdfView.scaleFactorForSizeToFit == 0.0) ? 1.0 : _pdfView.scaleFactorForSizeToFit);
    int pageNo = (int)[_pdfView.document indexForPage:currentPage] + 1;
    float currentPageHeight = [currentPage boundsForBox:kPDFDisplayBoxMediaBox].size.height;
    CGFloat iOSNormalisedY = (yPos / _scaleRatio) - _pageSpaceRectHeight - ((_pageCount.intValue - pageNo) * currentPageHeight) + _documentHeight;
    
    if (iOSNormalisedY > currentPageHeight - _pageSpaceRectHeight && pageNo > 1) {
        currentPage = [_pdfView.document pageAtIndex:pageNo - 2];
        iOSNormalisedY -= currentPageHeight;
    }
    [_pdfView goToRect:CGRectMake(xPos,  iOSNormalisedY, _pageSpaceRectWidth, _pageSpaceRectHeight) onPage:currentPage];
    
    result([NSNumber numberWithBool: YES]);
}

- (void)setScale:(FlutterMethodCall*)call result:(FlutterResult)result {
    NSNumber* scale = call.arguments[@"scale"];
    _pdfView.scaleFactor = scale.doubleValue;
    result([NSNumber numberWithBool: YES]);
}

- (void)getCurrentPage:(FlutterMethodCall*)call result:(FlutterResult)result {
    _currentPage = [NSNumber numberWithUnsignedLong: [_pdfView.document indexForPage: _pdfView.currentPage]];
    result(_currentPage);
}

- (void)setPage:(FlutterMethodCall*)call result:(FlutterResult)result {
    NSDictionary<NSString*, NSNumber*>* arguments = [call arguments];
    NSNumber* page = arguments[@"page"];
    
    [_pdfView goToPage: [_pdfView.document pageAtIndex: page.unsignedLongValue ]];
    result([NSNumber numberWithBool: YES]);
}

- (void)onUpdateSettings:(FlutterMethodCall*)call result:(FlutterResult)result {
    result(nil);
}

- (void)setZoomLimits:(FlutterMethodCall*)call {
    NSDictionary<NSString*, NSNumber*>* arguments = [call arguments];
    NSNumber* minZoom = arguments[@"minZoom"];
    NSNumber* maxZoom = arguments[@"maxZoom"];
    float minScale = minZoom.floatValue * _pdfView.scaleFactorForSizeToFit;
    float maxScale = maxZoom.floatValue * _pdfView.scaleFactorForSizeToFit;
    _pdfView.minScaleFactor = minScale != 0.0 ? minScale : minZoom.floatValue;
    _pdfView.maxScaleFactor = maxScale != 0.0 ? maxScale : maxZoom.floatValue;
}

-(void)handlePageChanged:(NSNotification*)notification {
    [_controller invokeChannelMethod:@"onPageChanged" arguments:@{@"page" : [NSNumber numberWithUnsignedLong: [_pdfView.document indexForPage: _pdfView.currentPage]], @"total" : [NSNumber numberWithUnsignedLong: [_pdfView.document pageCount]]}];
}

-(void)handleRenderCompleted: (NSNumber*)pages {
    [_controller invokeChannelMethod:@"onRender" arguments:@{@"pages" : pages}];
    [self startObserving];
}

- (void)handleOnDraw {
    [_controller invokeChannelMethod:@"onDraw" arguments:@{}];
}

- (void)PDFViewWillClickOnLink:(PDFView *)sender
                       withURL:(NSURL *)url{
    if (!_preventLinkNavigation){
        NSDictionary *options = @{};
        [[UIApplication sharedApplication] openURL:url options:options completionHandler:^(BOOL success) {
            if (success) {
                NSLog(@"URL opened successfully");
            } else {
                NSLog(@"Failed to open URL");
            }
        } ];
    }
    [_controller invokeChannelMethod:@"onLinkHandler" arguments:url.absoluteString];
}

- (void) onDoubleTap: (UITapGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateEnded) {
        if ([_pdfView scaleFactor] == _pdfView.scaleFactorForSizeToFit) {
            CGPoint point = [recognizer locationInView:_pdfView];
            PDFPage* page = [_pdfView pageForPoint:point nearest:YES];
            PDFPoint pdfPoint = [_pdfView convertPoint:point toPage:page];
            PDFRect rect = [page boundsForBox:kPDFDisplayBoxMediaBox];
            PDFDestination* destination = [[PDFDestination alloc] initWithPage:page atPoint:CGPointMake(pdfPoint.x - (rect.size.width / 4),pdfPoint.y + (rect.size.height / 4))];
            [UIView animateWithDuration:0.2 animations:^{
                self-> _pdfView.scaleFactor = self->_pdfView.scaleFactorForSizeToFit *2;
                [self->_pdfView goToDestination:destination];
            }];
        } else {
            [UIView animateWithDuration:0.2 animations:^{
                self->_pdfView.scaleFactor = self->_pdfView.scaleFactorForSizeToFit;
            }];
        }
    }
}

@end
