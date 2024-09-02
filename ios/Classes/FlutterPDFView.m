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
    _pdfView = [[FLTPDFView new] initWithFrame:frame arguments:args controler:self];
    _viewId = viewId;
    
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
    } else if ([[call method] isEqualToString:@"getPositionAndScale"]) {
        [_pdfView getPositionAndScale:call result:result];
    } else if ([[call method] isEqualToString:@"setPositionAndScale"]) {
        [_pdfView setPositionAndScale:call result:result];
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
    FLTPDFViewController* _controler;
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
}

- (instancetype)initWithFrame:(CGRect)frame
                    arguments:(id _Nullable)args
                    controler:(nonnull FLTPDFViewController *)controler {
    if ([super init]) {
        _controler = controler;
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
            [_controler invokeChannelMethod:@"onError" arguments:@{@"error" : @"cannot create document: File not in PDF format or corrupted."}];
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
        }
        
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
    return self;
}


- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    __weak __typeof__(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf onDraw];
    });
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
    _scrollView.delegate = self;
    
    _pageSpaceRect = [_pdfView convertRect:_pdfView.bounds toPage:_pdfView.currentPage];
    __weak __typeof__(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf handleRenderCompleted:[NSNumber numberWithUnsignedLong: [self->_pdfView.document pageCount]]];
    });
}

- (UIView*)view {
    return _pdfView;
}


- (void)getPageCount:(FlutterMethodCall*)call result:(FlutterResult)result {
    _pageCount = [NSNumber numberWithUnsignedLong: [[_pdfView document] pageCount]];
    result(_pageCount);
}

- (void)getCurrentPageSize:(FlutterMethodCall*)call result:(FlutterResult)result {
    CGRect bounds = _pdfView.documentView.bounds;
    NSArray *size = @[[NSNumber numberWithFloat:bounds.size.width], [NSNumber numberWithFloat:bounds.size.height]];
    result(size);
}

- (void)getPositionAndScale:(FlutterMethodCall*)call result:(FlutterResult)result {
    _pageSpaceRect = [_pdfView convertRect:_pdfView.bounds toPage:_pdfView.currentPage];
    float zoom = _pdfView.scaleFactor;
    float scaleRatio = _screenScale * ((_pdfView.scaleFactorForSizeToFit == 0.0) ? 1.0 : _pdfView.scaleFactorForSizeToFit);
    
    float flutterNormalisedY = (_pageSpaceRect.origin.y + _pageSpaceRect.size.height - _pdfView.documentView.bounds.size.height) * scaleRatio;
    
    //NSLog(@"get flutterNormalisedY: (%f + %f - %f) * (%f * ((%f == 0.0) ? 1.0 : %f))", _pageSpaceRect.origin.y, _pageSpaceRect.size.height, _pdfView.documentView.bounds.size.height, _screenScale, _pdfView.scaleFactorForSizeToFit, _pdfView.scaleFactorForSizeToFit);
    
    //NSLog(@"get y: %f", flutterNormalisedY);
    NSArray *posAndScale = @[[NSNumber numberWithFloat:MAX(_pageSpaceRect.origin.x, 0)], [NSNumber numberWithFloat:flutterNormalisedY], [NSNumber numberWithFloat:zoom]];
    result(posAndScale);
}

- (void)setPositionAndScale:(FlutterMethodCall*)call result:(FlutterResult)result {
    NSDictionary<NSString*, NSNumber*>* arguments = [call arguments];
    NSNumber* xPos = arguments[@"xPos"];
    NSNumber* yPos = arguments[@"yPos"];
    NSNumber* scale = arguments[@"scale"];
    float scaleRatio = _screenScale * ((_pdfView.scaleFactorForSizeToFit == 0.0) ? 1.0 : _pdfView.scaleFactorForSizeToFit);
    
    float iOSNormalisedY = yPos.floatValue / scaleRatio - _pageSpaceRect.size.height + _pdfView.documentView.bounds.size.height;
    
    //NSLog(@"set iOSNormalisedY: (%f / (%f * ((%f == 0.0) ? 1.0 : %f))) - %f + %f", yPos.floatValue, _screenScale, _pdfView.scaleFactorForSizeToFit, _pdfView.scaleFactorForSizeToFit, _pageSpaceRect.size.height, _pdfView.documentView.bounds.size.height);
    
    //NSLog(@"set y: %f", iOSNormalisedY);
    [_pdfView goToRect:CGRectMake(xPos.floatValue, iOSNormalisedY, _pageSpaceRect.size.width, _pageSpaceRect.size.height) onPage:_pdfView.currentPage];
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
    [_controler invokeChannelMethod:@"onPageChanged" arguments:@{@"page" : [NSNumber numberWithUnsignedLong: [_pdfView.document indexForPage: _pdfView.currentPage]], @"total" : [NSNumber numberWithUnsignedLong: [_pdfView.document pageCount]]}];
}

-(void)handleRenderCompleted: (NSNumber*)pages {
    [_controler invokeChannelMethod:@"onRender" arguments:@{@"pages" : pages}];
}

- (void)onDraw {
    [_controler invokeChannelMethod:@"onDraw" arguments:@{}];
}

- (void)PDFViewWillClickOnLink:(PDFView *)sender
                       withURL:(NSURL *)url{
    if (!_preventLinkNavigation){
        [[UIApplication sharedApplication] openURL:url options:@{}.mutableCopy completionHandler:nil];
    }
    [_controler invokeChannelMethod:@"onLinkHandler" arguments:url.absoluteString];
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
