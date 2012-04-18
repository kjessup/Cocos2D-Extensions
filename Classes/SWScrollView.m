//
//  SWScrollView.m
//  SWGameLib
//
//
//  Copyright (c) 2010 Sangwoo Im
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, ccsubject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//  
//  Created by Sangwoo Im on 6/3/10.
//  Copyright 2010 Sangwoo Im. All rights reserved.
//
////////////////////////////////////////////////////////////////////////////////////////////////////
// Modified by Dean Morris
// Wombat Entertainment www.wombatentertainment.com
// 18-April-2012
//
// * Handles clipping properly on ALL devices - old non retina phones were a bit dodgy on the original
// * Added support for Mac - no multi touch, but the panning and scrolling works fine
// * Added methods to pan and zoom on demand, at the same time
////////////////////////////////////////////////////////////////////////////////////////////////////

#import "SWScrollView.h"
#import "CCActionInterval.h"
#import "CCActionTween.h"
#import "CCActionInstant.h"
#import "CGPointExtension.h"
#import "CCTouchDispatcher.h"
#import "CCGrid.h"
#import "CCDirector.h"
#import "CCNode+Autolayout.h"
#include <sys/types.h>
#include <sys/sysctl.h>
#ifndef __IPHONE_OS_VERSION_MAX_ALLOWED
//#import "AppDelegate.h"
#import "CCDirectorMac.h"
#endif

#define SCROLL_DEACCEL_RATE  0.95f
#define SCROLL_DEACCEL_DIST  1.0f
#define BOUNCE_DURATION      0.35f
#define INSET_RATIO          0.3f

@interface SWScrollView()
/**
 * container is a protected property
 */
@property (nonatomic, retain) CCNode  *container_;
/**
 * initial touch point
 */
@property (nonatomic, assign) CGPoint touchPoint_;
/**
 * determines whether touch is moved after begin phase
 */
@property (nonatomic, assign) BOOL    touchMoved_;
@end

@interface SWScrollView (Private)
/**
 * Init this object with a given size to clip its content.
 *
 * @param size view size
 * @return initialized scroll view object
 */
-(id)initWithViewSize:(CGSize)size;
/**
 * Relocates the container at the proper offset, in bounds of max/min offsets.
 *
 * @param animated If YES, relocation is animated
 */
-(void)relocateContainer:(BOOL)animated;
/**
 * implements auto-scrolling behavior. change SCROLL_DEACCEL_RATE as needed to choose
 * deacceleration speed. it must be less than 1.0f.
 *
 * @param dt delta
 */
-(void)deaccelerateScrolling:(ccTime)dt;
/**
 * This method makes sure auto scrolling causes delegate to invoke its method
 */
-(void)performedAnimatedScroll:(ccTime)dt;
/**
 * Expire animated scroll delegate calls
 */
-(void)stoppedAnimatedScroll:(CCNode *)node;
/**
 * clip this view so that outside of the visible bounds can be hidden.
 */
-(void)beforeDraw;
/**
 * retract what's done in beforeDraw so that there's no side effect to
 * other nodes.
 */
-(void)afterDraw;
/**
 * Zoom handling
 */
-(void)handleZoom;
/**
 * Computes inset for bouncing
 */
-(void)computeInsets;
@end


@implementation SWScrollView
@synthesize direction     = direction_;
@synthesize clipsToBounds  = clipsToBounds_;
@synthesize viewSize      = viewSize_;
@synthesize bounces       = bounces_;
@synthesize isDragging    = isDragging_;
@synthesize delegate      = delegate_;
@synthesize touchPoint_;
@synthesize touchMoved_;
@synthesize container_;
@synthesize maxZoomScale = maxScale_;
@synthesize minZoomScale = minScale_;
@dynamic zoomScale;

@dynamic contentOffset;

/*-----------------------------------------------------------------------------------------------
 * onEnter
 *-----------------------------------------------------------------------------------------------*/ 
-(void)onEnter{
	
	// Allow touches
#ifdef __IPHONE_OS_VERSION_MAX_ALLOWED
	[[CCDirector sharedDirector].touchDispatcher addTargetedDelegate:self priority:kInterfacePriorityScrollLayer swallowsTouches:NO];
	[super onEnter];
#else	
	[[CCDirector sharedDirector].eventDispatcher addMouseDelegate:self priority:kInterfacePriorityScrollLayer];
	[[CCDirector sharedDirector].eventDispatcher addKeyboardDelegate:self priority:kInterfacePriorityScrollLayer];
	[super onEnter];
#endif
	
}
/*-----------------------------------------------------------------------------------------------
 * onExit
 *-----------------------------------------------------------------------------------------------*/ 
-(void)onExit{
#ifdef __IPHONE_OS_VERSION_MAX_ALLOWED
	// Turn on the touch handler
	[[CCDirector sharedDirector].touchDispatcher  removeDelegate:self];
	[super onExit];
#else	
	[[CCDirector sharedDirector].eventDispatcher removeMouseDelegate:self];
    [[CCDirector sharedDirector].eventDispatcher removeKeyboardDelegate:self];
	[super onExit];
#endif
}
/*-----------------------------------------------------------------------------------------------
 * Get the hardware version
 *-----------------------------------------------------------------------------------------------*/ 
-(void)setOrientation{
	flipOrientation = NO;
	
	size_t size;
	sysctlbyname("hw.machine", NULL, &size, NULL, 0);
	char *answer = malloc(size);
	sysctlbyname("hw.machine", answer, &size, NULL, 0);
	NSString *platform = [NSString stringWithCString:answer encoding:NSUTF8StringEncoding];
	free(answer);
	
	//CCLOG(@"platform:[%@]", platform);
	if([platform isEqualToString:@"iPhone1,1"])
		flipOrientation = YES;
	else if([platform isEqualToString:@"iPhone1,2"])
		flipOrientation = YES;
	else if([platform isEqualToString:@"iPod Touch 1G"])
		flipOrientation = YES;
	else if([platform isEqualToString:@"iPod Touch 2G"])
		flipOrientation = YES;
	//CCLOG(@"flipOrientation:%d", flipOrientation);
	
#ifdef __IPHONE_OS_VERSION_MAX_ALLOWED
	if(flipOrientation)
		deviceScale = 1;
	else if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
		deviceScale = 1;
	else
		deviceScale = [[CCDirector sharedDirector] contentScaleFactor];
#else
	deviceScale = 1;
#endif
	
}

#pragma mark -
#pragma mark init
+(id)viewWithViewSize:(CGSize)size {
    return [[[self alloc] initWithViewSize:size] autorelease];
}
+(id)viewWithViewSize:(CGSize)size container:(CCNode *)container {
    return [[[self alloc] initWithViewSize:size container:container] autorelease];
}
-(id)initWithViewSize:(CGSize)size {
    return [self initWithViewSize:size container:nil];
}
-(id)initWithViewSize:(CGSize)size container:(CCNode *)container {
    if ((self = [super init])) {
        self.container_ = container;
        self.viewSize   = size;
        
        if (!self.container_) {
            self.container_ = [CCLayer node];
        }
/*
 * These touch activations are not required any more, as we're using a touch dispatcher instead, as it
 * allows us to prioritise touches between layers
#ifdef __IPHONE_OS_VERSION_MAX_ALLOWED
		self.isTouchEnabled = YES;
#else
        [[CCDirector sharedDirector].touchDispatcher addTargetedDelegate:self priority:0 swallowsTouches:NO];
		self.isMouseEnabled = YES;
#endif
 */
        touches_               = [NSMutableArray new];
        delegate_              = nil;
        bounces_               = YES;
        clipsToBounds_          = YES;
        container_.contentSize = CGSizeZero;
        direction_             = SWScrollViewDirectionBoth;
        container_.position    = ccp(0.0f, 0.0f);
        touchLength_           = 0.0f;
        
        [self addChild:container_];
        minScale_ = maxScale_ = 1.0f;
        
        [self setOrientation];
        winSize = [[CCDirector sharedDirector]winSize];
    } else {
        NSLog(@"SWScrollView.init init failed");
        return nil;
    }
	
    return self;
}
-(id)init {
    NSAssert(NO, @"SWScrollView: DO NOT initialize SWScrollview directly.");
    return nil;
}
-(void)dealloc {
    [touches_ release];
    [container_ release];
    [super dealloc];
}
-(void)registerWithTouchDispatcher {
#ifdef __IPHONE_OS_VERSION_MAX_ALLOWED
    [[CCDirector sharedDirector].touchDispatcher addTargetedDelegate:self priority:0 swallowsTouches:NO];
#else
	[super onEnter];
#endif
}

-(BOOL)isNodeVisible:(CCNode *)node {
    const CGPoint offset = [self contentOffset];
    const CGSize  size   = [self viewSize];
    const float   scale  = [self zoomScale];
    
    CGRect viewRect;
    
    viewRect = CGRectMake(-offset.x/scale, -offset.y/scale, size.width/scale, size.height/scale); 
	//CCLOG(@"viewRect:%@ node bounds:%@", NSStringFromCGRect(viewRect), NSStringFromCGRect([node boundingBox]));
	
    return CGRectIntersectsRect(viewRect, [node boundingBox]);
}
-(void)pause:(id)sender {
    id child;
    [container_ pauseSchedulerAndActions];
    CCARRAY_FOREACH(container_.children, child) {
        if ([child respondsToSelector:@selector(pause:)]) {
            [child performSelector:@selector(pause:) withObject:sender];
        }
    }
}
-(void)resume:(id)sender {
    id child;
    CCARRAY_FOREACH(container_.children, child) {
        if ([child respondsToSelector:@selector(resume:)]) {
            [child performSelector:@selector(resume:) withObject:sender];
        }
    }
    [container_ resumeSchedulerAndActions];
}
#pragma mark -
#pragma mark Properties
-(void)setIsTouchEnabled:(BOOL)e {
    [super setIsTouchEnabled:e];
    if (!e) {
        isDragging_ = NO;
        touchMoved_ = NO;
        [touches_ removeAllObjects];
    }
}
/*-----------------------------------------------------------------------------------------------
 * Set the zoom and offset, animated or not
 *-----------------------------------------------------------------------------------------------*/ 
-(void)setZoomAndOffset:(float)scale offset:(CGPoint)offset animated:(BOOL)animated{
    if (animated) {
        [self setZoomAndOffset:scale offset:offset animatedInDuration:BOUNCE_DURATION];
    } else {
        [self setZoomAndOffset:scale offset:offset];
    }
}

/*-----------------------------------------------------------------------------------------------
 * Called once the scroll and zoom is complete
 *-----------------------------------------------------------------------------------------------*/ 
-(void)scrollAndZoomComplete{
    [self unschedule:@selector(performedAnimatedScroll:)];

    if ([delegate_ respondsToSelector:@selector(scrollViewDidZoom:)]) {
        [delegate_ scrollViewDidZoom:self];
    }
    if ([delegate_ respondsToSelector:@selector(scrollViewDidScroll:)]) {
        [delegate_ scrollViewDidScroll:self];
    }
}

/*-----------------------------------------------------------------------------------------------
 * Set the zoom and offset, move over the given duration
 *-----------------------------------------------------------------------------------------------*/ 
-(void)setZoomAndOffset:(float)scale offset:(CGPoint)offset animatedInDuration:(ccTime)time{
    //CCLOG(@"setZoomAndOffset offset:(%f,%f)", offset.x, offset.y);
    
    if(time <= 0){
        [self setZoomAndOffset:scale offset:offset];
        return;
    }
    
    CCSequence *action = [CCSequence actions:
                          	[CCSpawn actions:
                           		[CCMoveTo actionWithDuration:time position:offset],
                           		[CCScaleTo actionWithDuration:time scale:scale],
                             	nil],
                          	[CCCallFunc actionWithTarget:self selector:@selector(scrollAndZoomComplete)],
                          nil];
    [container_ stopAllActions];
    [container_ runAction:action];

}

/*-----------------------------------------------------------------------------------------------
 * Start the player's turn
 *-----------------------------------------------------------------------------------------------*/ 
-(void)setZoomAndOffset:(float)scale offset:(CGPoint)offset{
    [self setContentOffset:offset animated:NO];
    [self setZoomScale:scale animated:NO];
}

-(void)setContentOffset:(CGPoint)offset {
	//CCLOG(@"SWScrollView.setContentOffset");
    [self setContentOffset:offset animated:NO];
}
-(void)setContentOffset:(CGPoint)offset animated:(BOOL)animated {
	//CCLOG(@"SWScrollView.setContentOffset offset:%@ animated:%d", NSStringFromCGPoint(offset), animated);
    if (animated) { //animate scrolling
		//CCLOG(@"animated");
        [self setContentOffset:offset animatedInDuration:BOUNCE_DURATION];
    } else { //set the container position directly
		//CCLOG(@"not animated");
        if (!bounces_) {
			//CCLOG(@"no bounce");
            const CGPoint minOffset = [self minContainerOffset];
            const CGPoint maxOffset = [self maxContainerOffset];
            
            offset.x = MAX(minOffset.x, MIN(maxOffset.x, offset.x));
            offset.y = MAX(minOffset.y, MIN(maxOffset.y, offset.y));
        }
		//CCLOG(@"after bounce");
        container_.position = offset;
        if([delegate_ respondsToSelector:@selector(scrollViewDidScroll:)]) {
			//CCLOG(@"does respond");
            [delegate_ scrollViewDidScroll:self];   
        }
    }
}
-(void)setContentOffset:(CGPoint)offset animatedInDuration:(ccTime)dt {
    CCFiniteTimeAction *scroll, *expire;
    
    scroll = [CCMoveTo actionWithDuration:dt position:offset];
    expire = [CCCallFunc actionWithTarget:self selector:@selector(stoppedAnimatedScroll:)];
    [container_ runAction:[CCSequence actions:scroll, expire, nil]];
    [self schedule:@selector(performedAnimatedScroll:)];
}
-(CGPoint)contentOffset {
    return container_.position;
}
-(void)setZoomScale:(CGFloat)s {
    if (container_.scale != s) {
        CGPoint oldCenter, newCenter;
        CGPoint center;
        
        if (touchLength_ == 0.0f) {
            center = ccp(viewSize_.width*0.5f, viewSize_.height*0.5f);
            center = [self convertToWorldSpace:center];
        } else {
            center = touchPoint_;
        }
        
        oldCenter = [container_ convertToNodeSpace:center];
        container_.scale = MAX(minScale_, MIN(maxScale_, s));
        newCenter = [container_ convertToWorldSpace:oldCenter];
        
        const CGPoint offset = ccpSub(center, newCenter);
        if ([delegate_ respondsToSelector:@selector(scrollViewDidZoom:)]) {
            [delegate_ scrollViewDidZoom:self];
        }
		
		[self computeInsets];
        [self setContentOffset:ccpAdd(container_.position,offset)];
    }
}
-(CGFloat)zoomScale {
    return container_.scale;
}
-(void)setZoomScale:(float)s animated:(BOOL)animated {
    if (animated) {
        [self setZoomScale:s animatedInDuration:BOUNCE_DURATION];
    } else {
        [self setZoomScale:s];
    }
}
-(void)setZoomScale:(float)s animatedInDuration:(ccTime)dt {
    if (dt > 0) {
        if (container_.scale != s) {
            CCActionTween *scaleAction;
            scaleAction = [CCActionTween actionWithDuration:dt
                                                        key:@"zoomScale"
                                                       from:container_.scale
                                                         to:s];
            [self runAction:scaleAction];
        }
    } else {
        [self setZoomScale:s];
    }
}
-(void)setViewSize:(CGSize)size {
    if (!CGSizeEqualToSize(viewSize_, size)) {
        viewSize_ = size;
		[self computeInsets];
    }
	//CCLOG(@"setViewSize:%@", NSStringFromCGSize(viewSize_));
}
#pragma mark -
#pragma mark Private
-(void)computeInsets {
	maxInset_ = [self maxContainerOffset];
	maxInset_ = ccp(maxInset_.x + viewSize_.width * INSET_RATIO,
					maxInset_.y + viewSize_.height * INSET_RATIO);
	minInset_ = [self minContainerOffset];
	minInset_ = ccp(minInset_.x - viewSize_.width * INSET_RATIO,
					minInset_.y - viewSize_.height * INSET_RATIO);
}
-(void)relocateContainer:(BOOL)animated {
    CGPoint oldPoint, min, max;
    CGFloat newX, newY;
    
    min = [self minContainerOffset];
    max = [self maxContainerOffset];
    
    oldPoint = container_.position;
    newX     = oldPoint.x;
    newY     = oldPoint.y;
    if (direction_ == SWScrollViewDirectionBoth || direction_ == SWScrollViewDirectionHorizontal) {
        newX     = MIN(newX, max.x);
        newX     = MAX(newX, min.x);
    }
    if (direction_ == SWScrollViewDirectionBoth || direction_ == SWScrollViewDirectionVertical) {
        newY     = MIN(newY, max.y);
        newY     = MAX(newY, min.y);
    }
    if (newY != oldPoint.y || newX != oldPoint.x) {
        [self setContentOffset:ccp(newX, newY) animated:animated];
    }
}
-(CGPoint)maxContainerOffset {
    return ccp(0.0f, 0.0f);
}
-(CGPoint)minContainerOffset {
	//CCLOG(@"minContainerOffset view height:%f container height:%f scale:%f", viewSize_.height, container_.contentSize.height, container_.scaleY);
	
    return ccp(viewSize_.width - container_.contentSize.width * container_.scaleX, 
               viewSize_.height - container_.contentSize.height * container_.scaleY);
}
-(void)deaccelerateScrolling:(ccTime)dt {
    if (isDragging_) {
        [self unschedule:@selector(deaccelerateScrolling:)];
        return;
    }
    
    CGFloat newX, newY;
    CGPoint maxInset, minInset;
    
    container_.position = ccpAdd(container_.position, scrollDistance_);
    
    if (bounces_) {
        maxInset = maxInset_;
        minInset = minInset_;
    } else {
        maxInset = [self maxContainerOffset];
        minInset = [self minContainerOffset];
    }
    
    //check to see if offset lies within the inset bounds
    newX     = MIN(container_.position.x, maxInset.x);
    newX     = MAX(newX, minInset.x);
    newY     = MIN(container_.position.y, maxInset.y);
    newY     = MAX(newY, minInset.y);
    
    scrollDistance_     = ccpSub(scrollDistance_ , ccp(newX - container_.position.x, newY - container_.position.y));
    scrollDistance_     = ccpMult(scrollDistance_, SCROLL_DEACCEL_RATE);
    [self setContentOffset:ccp(newX,newY)];
    
    if (ccpLengthSQ(scrollDistance_) <= SCROLL_DEACCEL_DIST*SCROLL_DEACCEL_DIST ||
        newX == maxInset.x || newX == minInset.x ||
        newY == maxInset.y || newY == minInset.y) {
        [self unschedule:@selector(deaccelerateScrolling:)];
        [self relocateContainer:YES];
    }
}
-(void)stoppedAnimatedScroll:(CCNode *)node {
    [self unschedule:@selector(performedAnimatedScroll:)];
}
-(void)performedAnimatedScroll:(ccTime)dt {
    if (isDragging_) {
        [self unschedule:@selector(performedAnimatedScroll:)];
        return;
    }
    if ([delegate_ respondsToSelector:@selector(scrollViewDidScroll:)]) {
        [delegate_ scrollViewDidScroll:self];
    }
}

#pragma mark -
#pragma mark overriden
-(void)setAnchorPoint:(CGPoint)anchorPoint {
	CCLOG(@"The current implementation doesn't support anchor point change");
}
-(void)layoutChildren {
	[self relocateContainer:NO];
}
-(CGSize)contentSize {
    return CGSizeMake(container_.contentSize.width, container_.contentSize.height); 
}
-(void)setContentSize:(CGSize)size {
    container_.contentSize = size;
    maxInset_ = [self maxContainerOffset];
    maxInset_ = ccp(maxInset_.x + viewSize_.width * INSET_RATIO,
                    maxInset_.y + viewSize_.height * INSET_RATIO);
    minInset_ = [self minContainerOffset];
    minInset_ = ccp(minInset_.x - viewSize_.width * INSET_RATIO,
                    minInset_.y - viewSize_.height * INSET_RATIO);
	//CCLOG(@"setContentSize max:%@ min:%@", NSStringFromCGPoint(maxInset_), NSStringFromCGPoint(minInset_));
}

/**
 * make sure all children go to the container
 */
-(void)addChild:(CCNode *)node  z:(NSInteger)z tag:(NSInteger)aTag {
    node.isRelativeAnchorPoint = YES;
    node.anchorPoint           = ccp(0.0f, 0.0f);
    if (container_ != node) {
		//CCLOG(@"Add to container");
        [container_ addChild:node z:z tag:aTag];
    } else {
		//CCLOG(@"Regular add");
        [super addChild:node z:z tag:aTag];
    }
}

/*-----------------------------------------------------------------------------------------------
 * Added by Dean Morris
 * If the child has gone into the container, get it back from there
 *-----------------------------------------------------------------------------------------------*/ 
-(CCNode *) getChildByTag:(NSInteger)aTag{
	if(container_ != nil)
		return [container_ getChildByTag:aTag];
	else
		return [super getChildByTag:aTag];
}

// Added by Dean Morris
-(void)removeChildByTag:(NSInteger)tag cleanup:(BOOL)cleanup{
	if(container_ != nil)
        [container_ removeChildByTag:tag cleanup:cleanup];
    else
        [super removeChildByTag:tag cleanup:cleanup];
}
-(void)removeChild:(CCNode *)node cleanup:(BOOL)cleanup{
    if(container_ != nil)
        [container_ removeChild:node cleanup:cleanup];
    else 
        [self removeChild:node cleanup:cleanup];
}

/*-----------------------------------------------------------------------------------------------
 * beforeDraw
 * clip this view so that outside of the visible bounds can be hidden.
 *-----------------------------------------------------------------------------------------------*/ 
-(void)beforeDraw {
    if (clipsToBounds_) {
        glEnable(GL_SCISSOR_TEST);
//        const CGFloat s = [[CCDirector sharedDirector] contentScaleFactor];
		CGPoint windowOffset = CGPointZero;
		
#ifdef __IPHONE_OS_VERSION_MAX_ALLOWED
		const CGFloat s = deviceScale;
#else
		CCDirectorMac *director = (CCDirectorMac *)[CCDirector sharedDirector];
		windowOffset = director.winOffset;
		CGSize windowSize = [director winSizeInPixels];
		const CGFloat s = windowSize.height / winSize.height;
		//CCLOG(@"->offset:%f,%f full:%d size:%fx%f  window:%fx%f scale:%f",  windowOffset.x, windowOffset.y, director.isFullScreen, windowSize.width, windowSize.height, winSize.width, winSize.height, s);
#endif
		
		if(!flipOrientation) {
	        glScissor(self.position.x*s + windowOffset.x, self.position.y*s + windowOffset.y, viewSize_.width*s, viewSize_.height*s);
			//CGSize temp =[[CCDirector sharedDirector]winSize];
			//CCLOG(@"no flip (%f,%f) %fx%f  scale:%f  screen:%fx%f", self.position.x*s + windowOffset.x, self.position.y*s + windowOffset.y, viewSize_.width*s, viewSize_.height*s, s, temp.width, temp.height);
			//CGPoint newPoint = [[CCDirector sharedDirector] convertToLogicalCoordinates:CGPointMake(self.position.x*s, self.position.y*s)];
			
		} else {
	        glScissor(self.position.y*s, winSize.width - self.position.x*s - viewSize_.width*s, viewSize_.height*s, viewSize_.width*s);
			//CCLOG(@"flip %f %f %f %f  scale:%f", winSize.height - self.position.x*s, winSize.width - self.position.y*s, viewSize_.width*s, viewSize_.height*s, deviceScale);
		}
    }
}

/*-----------------------------------------------------------------------------------------------
 * afterDraw
 * retract what's done in beforeDraw so that there's no side effect to
 * other nodes.
 *-----------------------------------------------------------------------------------------------*/ 
-(void)afterDraw {
    if (clipsToBounds_) {
        glDisable(GL_SCISSOR_TEST);
    }
}

#ifndef __IPHONE_OS_VERSION_MAX_ALLOWED
/*-----------------------------------------------------------------------------------------------
 * ccMouseDown
 *-----------------------------------------------------------------------------------------------*/ 
-(BOOL)ccMouseDown:(NSEvent *)touch{
	//CCLOG(@"SWScrollView.ccMouseDown");
    if (!self.visible) {
		//CCLOG(@"SWScrollView.ccMouseDown not visible");
        return NO;
    }
	
	// CGPoint eventLocation = [container_ convertToWorldSpace:[container_ convertTouchToNodeSpace:touch]];
	CGPoint eventLocation = [[CCDirector sharedDirector] convertEventToGL:touch];

    CGRect frame = CGRectMake(self.position.x, self.position.y, viewSize_.width, viewSize_.height);
	//CCLOG(@"SWScrollView.ccMouseDown location:%f,%f  frame:(%f,%f) -> (%fx%f) moved:%d touches:%ld", eventLocation.x, eventLocation.y, frame.origin.x, frame.origin.y, frame.size.width, frame.size.height, touchMoved_, [touches_ count]);
	
	//CCLOG(@"touch frame:%@", NSStringFromCGRect(frame));
    //dispatcher does not know about clipping. reject touches outside visible bounds.
	/*
    if ([touches_ count] > 2 ||
        touchMoved_          ||
        !CGRectContainsPoint(frame, eventLocation)) {
		CCLOG(@"SWScrollView.ccMouseDown outside");
        return NO;
    }
	 */
    if (touchMoved_          ||
        !CGRectContainsPoint(frame, eventLocation)) {
		//CCLOG(@"SWScrollView.ccMouseDown outside");
        return NO;
    }
	
	/*
    if (![touches_ containsObject:touch]) {
        [touches_ addObject:touch];
		CCLOG(@"SWScrollView.ccMouseDown add");
    }
	 */
   // if ([touches_ count] == 1) { // scrolling
		//CCLOG(@"SWScrollView.ccMouseDown scrolling");
        // touchPoint_     = [self convertTouchToNodeSpace:touch];
        touchPoint_     = [self convertToNodeSpace:eventLocation];
        touchMoved_     = NO;
        isDragging_     = YES; //dragging started
        scrollDistance_ = ccp(0.0f, 0.0f);
        touchLength_    = 0.0f;
//    } 
	/*else if ([touches_ count] == 2) {
		CCLOG(@"SWScrollView.ccMouseDown 2 touches");
		CGPoint point0_layer = [self convertToNodeSpace:[[CCDirector sharedDirector] convertEventToGL:[touches_ objectAtIndex:0]]];
		CGPoint point1_layer = [self convertToNodeSpace:[[CCDirector sharedDirector] convertEventToGL:[touches_ objectAtIndex:1]]];
		CGPoint point0_container = [container_ convertToNodeSpace:[[CCDirector sharedDirector] convertEventToGL:[touches_ objectAtIndex:0]]];
		CGPoint point1_container = [container_ convertToNodeSpace:[[CCDirector sharedDirector] convertEventToGL:[touches_ objectAtIndex:1]]];

        touchPoint_  = ccpMidpoint(point0_layer, point1_layer);
        touchLength_ = ccpDistance(point0_container, point1_container);
        isDragging_  = NO;
    } */
	return YES;
}

/*-----------------------------------------------------------------------------------------------
 * ccMouseDragged
 *-----------------------------------------------------------------------------------------------*/ 
-(BOOL) ccMouseDragged:(NSEvent *)touch{
	// CCLOG(@"SWScrollView.ccMouseDragged");
	
    if (!self.visible) {
		//CCLOG(@"SWScrollView.ccMouseDragged not visible");
        return NO;
    }

	//if ([touches_ count] == 1 && isDragging_) { // scrolling
	if (isDragging_) { // scrolling
	//	CCLOG(@"SWScrollView.ccMouseDragged scrolling");
		CGPoint moveDistance, newPoint;
		CGRect  frame;
		CGFloat newX, newY;
		
		touchMoved_  = YES;
		frame        = CGRectMake(self.position.x, self.position.y, viewSize_.width, viewSize_.height);
		//newPoint     = [self convertTouchToNodeSpace:[touches_ objectAtIndex:0]];
		newPoint     = [self convertToNodeSpace:[[CCDirector sharedDirector] convertEventToGL:touch]];
		
		moveDistance = ccpSub(newPoint, touchPoint_);
		touchPoint_  = newPoint;
		
		if (CGRectContainsPoint(frame, [self convertToWorldSpace:newPoint])) {
			switch (direction_) {
				case SWScrollViewDirectionVertical:
					moveDistance = ccp(0.0f, moveDistance.y);
					break;
				case SWScrollViewDirectionHorizontal:
					moveDistance = ccp(moveDistance.x, 0.0f);
					break;
				default:
					break;
			}
			container_.position = ccpAdd(container_.position, moveDistance);
			
			//check to see if offset lies within the inset bounds
			newX     = MIN(container_.position.x, maxInset_.x);
			newX     = MAX(newX, minInset_.x);
			newY     = MIN(container_.position.y, maxInset_.y);
			newY     = MAX(newY, minInset_.y);
			
			scrollDistance_     = ccpSub(moveDistance, ccp(newX - container_.position.x, newY - container_.position.y));
			[self setContentOffset:ccp(newX, newY)];
		}
	} 
	/* else if ([touches_ count] == 2 && !isDragging_) {
		touchMoved_ = YES;
		CGPoint point0 = [container_  convertToNodeSpace:[[CCDirector sharedDirector] convertEventToGL:[touches_ objectAtIndex:0]]];
		CGPoint point1 = [container_ convertToNodeSpace:[[CCDirector sharedDirector] convertEventToGL:[touches_ objectAtIndex:1]]];
		const CGFloat len = ccpDistance([container_ convertToNodeSpace:point0],
										[container_ convertToNodeSpace:point1]);
		[self setZoomScale:self.zoomScale*len/touchLength_];
	}
	 */
	return NO;
}

/*-----------------------------------------------------------------------------------------------
 * ccMouseUp
 *-----------------------------------------------------------------------------------------------*/ 
-(BOOL) ccMouseUp:(NSEvent *)touch{
	//CCLOG(@"SWScrollView.ccMouseUp");
    if (!self.visible) {
        return NO;
    }
 //   if ([touches_ containsObject:touch]) {
		//CCLOG(@"SWScrollView.ccMouseUp contains object");
        if (touchMoved_) {
            [self schedule:@selector(deaccelerateScrolling:)];
        }
//        [touches_ removeObject:touch];
//    } 
//    if ([touches_ count] == 0) {
		//CCLOG(@"SWScrollView.ccMouseUp no touches");
        isDragging_ = NO;    
        touchMoved_ = NO;
//    }
	return NO;
}
#endif


#ifdef __IPHONE_OS_VERSION_MAX_ALLOWED

-(BOOL)ccTouchBegan:(UITouch *)touch withEvent:(UIEvent *)event {
    if (!self.visible) {
        return NO;
    }
    CGRect frame;
    
    frame = CGRectMake(self.position.x, self.position.y, viewSize_.width, viewSize_.height);
	//CCLOG(@"touch frame:%@", NSStringFromCGRect(frame));
    //dispatcher does not know about clipping. reject touches outside visible bounds.
    if ([touches_ count] > 2 ||
        touchMoved_          ||
        !CGRectContainsPoint(frame, [container_ convertToWorldSpace:[container_ convertTouchToNodeSpace:touch]])) {
        return NO;
    }
	
    if (![touches_ containsObject:touch]) {
        [touches_ addObject:touch];
    }
    if ([touches_ count] == 1) { // scrolling
        touchPoint_     = [self convertTouchToNodeSpace:touch];
        touchMoved_     = NO;
        isDragging_     = YES; //dragging started
        scrollDistance_ = ccp(0.0f, 0.0f);
        touchLength_    = 0.0f;
    } else if ([touches_ count] == 2) {
        touchPoint_  = ccpMidpoint([self convertTouchToNodeSpace:[touches_ objectAtIndex:0]],
                                   [self convertTouchToNodeSpace:[touches_ objectAtIndex:1]]);
        touchLength_ = ccpDistance([container_ convertTouchToNodeSpace:[touches_ objectAtIndex:0]],
                                   [container_ convertTouchToNodeSpace:[touches_ objectAtIndex:1]]);
        isDragging_  = NO;
    } 
	return YES;
}

-(void)ccTouchMoved:(UITouch *)touch withEvent:(UIEvent *)event {
    
    if (!self.visible) {
        return;
    }
    if ([touches_ containsObject:touch]) {
        if ([touches_ count] == 1 && isDragging_) { // scrolling
            CGPoint moveDistance, newPoint;
            CGRect  frame;
            CGFloat newX, newY;
            
            touchMoved_  = YES;
            frame        = CGRectMake(self.position.x, self.position.y, viewSize_.width, viewSize_.height);
            newPoint     = [self convertTouchToNodeSpace:[touches_ objectAtIndex:0]];
            moveDistance = ccpSub(newPoint, touchPoint_);
            touchPoint_  = newPoint;
            
            if (CGRectContainsPoint(frame, [self convertToWorldSpace:newPoint])) {
                switch (direction_) {
                    case SWScrollViewDirectionVertical:
                        moveDistance = ccp(0.0f, moveDistance.y);
                        break;
                    case SWScrollViewDirectionHorizontal:
                        moveDistance = ccp(moveDistance.x, 0.0f);
                        break;
                    default:
                        break;
                }
                container_.position = ccpAdd(container_.position, moveDistance);
                
                //check to see if offset lies within the inset bounds
                newX     = MIN(container_.position.x, maxInset_.x);
                newX     = MAX(newX, minInset_.x);
                newY     = MIN(container_.position.y, maxInset_.y);
                newY     = MAX(newY, minInset_.y);
                
                scrollDistance_     = ccpSub(moveDistance, ccp(newX - container_.position.x, newY - container_.position.y));
                [self setContentOffset:ccp(newX, newY)];
            }
        } else if ([touches_ count] == 2 && !isDragging_) {
			touchMoved_ = YES;
            const CGFloat len = ccpDistance([container_ convertTouchToNodeSpace:[touches_ objectAtIndex:0]],
                                            [container_ convertTouchToNodeSpace:[touches_ objectAtIndex:1]]);
            [self setZoomScale:self.zoomScale*len/touchLength_];
        }
    }
}
-(void)ccTouchEnded:(UITouch *)touch withEvent:(UIEvent *)event {
    if (!self.visible) {
        return;
    }
    if ([touches_ containsObject:touch]) {
        if (touchMoved_) {
            [self schedule:@selector(deaccelerateScrolling:)];
        }
        [touches_ removeObject:touch];
    } 
    if ([touches_ count] == 0) {
        isDragging_ = NO;    
        touchMoved_ = NO;
    }
}
-(void)ccTouchCancelled:(UITouch *)touch withEvent:(UIEvent *)event {
    if (!self.visible) {
        return;
    }
    [touches_ removeObject:touch]; 
    if ([touches_ count] == 0) {
        isDragging_ = NO;    
        touchMoved_ = NO;
    }
}
#endif

@end