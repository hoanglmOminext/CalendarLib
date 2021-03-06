//
//  ShiftDayPlannerView.m
//  Graphical Calendars Library for iOS
//
//  Distributed under the MIT License
//  Get the latest version from here:
//
//	https://github.com/jumartin/Calendar
//
//  Copyright (c) 2014-2015 Julien Martin
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

#import "ShiftDayPlannerView.h"
#import "NSCalendar+MGCAdditions.h"
#import "MGCDateRange.h"
#import "MGCReusableObjectQueue.h"
#import "ShiftTimedEventsViewLayout.h"
#import "ShiftDayColumnCell.h"
#import "MGCEventCell.h"
#import "MGCEventView.h"
#import "ShiftEventView.h"
#import "MGCInteractiveEventView.h"
#import "ShiftTimeRowsView.h"
#import "MGCAlignedGeometry.h"
#import "OSCache.h"
#import "ShiftLoadMoreView.h"
#import "ShiftButtonSelect.h"

// used to restrict scrolling to one direction / axis
typedef enum: NSUInteger
{
	ScrollDirectionUnknown = 0,
	ScrollDirectionLeft = 1 << 0,
	ScrollDirectionUp = 1 << 1,
	ScrollDirectionRight = 1 << 2,
	ScrollDirectionDown = 1 << 3,
	ScrollDirectionHorizontal = (ScrollDirectionLeft | ScrollDirectionRight),
	ScrollDirectionVertical = (ScrollDirectionUp | ScrollDirectionDown)
} ScrollDirection;


// collection views cell identifiers
static NSString* const EventCellReuseIdentifier = @"EventCellReuseIdentifier";
static NSString* const DimmingViewReuseIdentifier = @"DimmingViewReuseIdentifier";
static NSString* const DayColumnCellReuseIdentifier = @"DayColumnCellReuseIdentifier";
static NSString* const TimeRowCellReuseIdentifier = @"TimeRowCellReuseIdentifier";
static NSString* const MoreEventsViewReuseIdentifier = @"MoreEventsViewReuseIdentifier";   // test


// we only load in the collection views (2 * kDaysLoadingStep + 1) pages of (numberOfVisibleDays) days each at a time.
// this value can be tweaked for performance or smoother scrolling (between 2 and 4 seems reasonable)
static const NSUInteger kDaysLoadingStep = 2;

// minimum and maximum height of a one-hour time slot
static const CGFloat kMinHourSlotHeight = 20.;
static const CGFloat kMaxHourSlotHeight = 150.;


@interface MGCDayColumnViewFlowLayout : UICollectionViewFlowLayout
@end

@implementation MGCDayColumnViewFlowLayout

- (UICollectionViewLayoutInvalidationContext *)invalidationContextForBoundsChange:(CGRect)newBounds {
    
    UICollectionViewFlowLayoutInvalidationContext *context = (UICollectionViewFlowLayoutInvalidationContext *)[super invalidationContextForBoundsChange:newBounds];
    CGRect oldBounds = self.collectionView.bounds;
    context.invalidateFlowLayoutDelegateMetrics = !CGSizeEqualToSize(newBounds.size, oldBounds.size);
    return context;
}

// we keep this for iOS 8 compatibility. As of iOS 9, this is replaced by collectionView:targetContentOffsetForProposedContentOffset:
- (CGPoint)targetContentOffsetForProposedContentOffset:(CGPoint)proposedContentOffset
{
    id<UICollectionViewDelegate> delegate = (id<UICollectionViewDelegate>)self.collectionView.delegate;
    return [delegate collectionView:self.collectionView targetContentOffsetForProposedContentOffset:proposedContentOffset];
}


@end


@interface ShiftDayPlannerView () <UICollectionViewDataSource, ShiftTimedEventsViewLayoutDelegate,  UICollectionViewDelegateFlowLayout, ShiftTimeRowsViewDelegate>

// subviews
@property (nonatomic, readonly) UICollectionView *timedEventsView;
@property (nonatomic, readonly) UICollectionView *dayColumnsView;
@property (nonatomic, readonly) UIScrollView *timeScrollView;
@property (nonatomic, readonly) ShiftTimeRowsView *timeRowsView;
@property (nonatomic, readonly) ShiftLoadMoreView *ShiftLoadMoreView;
@property (nonatomic, readonly) ShiftButtonSelect *btnSelect;
@property (nonatomic,readonly) UIView *speratorVeticalView;
@property (nonatomic,readonly) UIView *speratorHoziView;

// collection view layouts
@property (nonatomic, readonly) ShiftTimedEventsViewLayout *timedEventsViewLayout;

@property (nonatomic) MGCReusableObjectQueue *reuseQueue;		// reuse queue for event views (MGCEventView)

@property (nonatomic, copy) NSDate *startDate;					// first currently loaded day in the collection views (might not be visible)
@property (nonatomic, readonly) NSDate *maxStartDate;			// maximum date for the start of a loaded page of the collection view - set with dateRange, nil for infinite scrolling
@property (nonatomic, readonly) NSUInteger numberOfLoadedDays;	// number of days loaded at once in the collection views
@property (nonatomic, readonly) MGCDateRange* loadedDaysRange;	// date range of all days currently loaded in the collection views
@property (nonatomic) MGCDateRange* previousVisibleDays;		// used by updateVisibleDaysRange to inform delegate about appearing / disappearing days

@property (nonatomic) NSMutableOrderedSet *loadingDays;			// set of dates with running activity indicator

@property (nonatomic, readonly) NSDate *firstVisibleDate;		// first fully visible day (!= visibleDays.start)

@property (nonatomic) CGFloat eventsViewInnerMargin;			// distance between top and first time line and between last line and bottom

@property (nonatomic) UIScrollView *controllingScrollView;		// the collection view which initiated scrolling - used for proper synchronization between the different collection views
@property (nonatomic) CGPoint scrollStartOffset;				// content offset in the controllingScrollView where scrolling started - used to lock scrolling in one direction
@property (nonatomic) ScrollDirection scrollDirection;			// direction or axis of the scroll movement
@property (nonatomic) NSDate *scrollTargetDate;                 // target date after scrolling (initiated programmatically or following pan or swipe gesture)

@property (nonatomic) MGCInteractiveEventView *interactiveCell;	// view used when dragging event around
@property (nonatomic) CGPoint interactiveCellTouchPoint;		// point where touch occured in interactiveCell coordinates
@property (nonatomic) MGCEventType interactiveCellType;			// current type of interactive cell
@property (nonatomic, copy) NSDate *interactiveCellDate;		// current date of interactice cell
@property (nonatomic) CGFloat interactiveCellTimedEventHeight;	// height of the dragged event
@property (nonatomic) BOOL isInteractiveCellForNewEvent;		// is the interactive cell for new event or existing one

@property (nonatomic) MGCEventType movingEventType;				// origin type of the event being moved
@property (nonatomic) NSUInteger movingEventIndex;				// origin index of the event being moved
@property (nonatomic, copy) NSDate *movingEventDate;			// origin date of the event being moved
@property (nonatomic) BOOL acceptsTarget;						// are the current date and type accepted for new event or existing one

@property (nonatomic, assign) NSTimer *dragTimer;				// timer used when scrolling while dragging

@property (nonatomic, copy) NSIndexPath *selectedCellIndexPath; // index path of the currently selected event cell
@property (nonatomic) MGCEventType selectedCellType;			// type of the currently selected event

@property (nonatomic) CGFloat hourSlotHeightForGesture;
@property (copy, nonatomic) dispatch_block_t scrollViewAnimationCompletionBlock;

@property (nonatomic) OSCache *dimmedTimeRangesCache;          // cache for dimmed time ranges (indexed by date)


@property (nonatomic) NSDate *indexDate;

@property (nonatomic) BOOL isLoadMore;

@property (nonatomic) CGFloat heightLoadMore;
@end


@implementation ShiftDayPlannerView

// readonly properties whose getter's defined are not auto-synthesized
@synthesize timedEventsView = _timedEventsView;
@synthesize dayColumnsView = _dayColumnsView;
//@synthesize backgroundView = _backgroundView;
@synthesize timeScrollView = _timeScrollView;
@synthesize timedEventsViewLayout = _timedEventsViewLayout;
@synthesize startDate = _startDate;
@synthesize ShiftLoadMoreView = _ShiftLoadMoreView;
@synthesize btnSelect = _btnSelect;
@synthesize speratorVeticalView = _speratorVeticalView;
@synthesize speratorHoziView = _speratorHoziView;
#pragma mark - Initialization

- (void)setup
{
    _heightLoadMore = 40;
    _isLimitLoadMore = NO;
    _isLoadMore = NO;
	_numberOfVisibleDays = 3;
	_hourSlotHeight = 30.;
	_timeColumnWidth = 80;
    _daySeparatorsColor = [UIColor lightGrayColor];
    _timeSeparatorsColor = [UIColor lightGrayColor];
    _currentTimeColor = [UIColor redColor];
    _eventsViewInnerMargin = 0;
    _dayHeaderHeight = 30.;
	_pagingEnabled = YES;
	_allowsSelection = YES;
	 _dimmingColor = [UIColor colorWithWhite:.9 alpha:.5];
	_reuseQueue = [[MGCReusableObjectQueue alloc] init];
	_loadingDays = [NSMutableOrderedSet orderedSetWithCapacity:14];
	
    _dimmedTimeRangesCache = [[OSCache alloc]init];
    _dimmedTimeRangesCache.countLimit = 200;
    
    _fontSizeNameHeaderDay = 12;
    _heightHeaderDayCell = 28;
    _maxCellVisible = 2;
    _sizeEventInSection = 48;
    _dayHeaderHeight = _maxCellVisible*_heightHeaderDayCell + _fontSizeNameHeaderDay+2+10;
    _indexDate = [self.calendar mgc_startOfDayForDate:[NSDate date]];
    
	self.backgroundColor = [UIColor whiteColor];
	self.autoresizesSubviews = NO;
	
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidReceiveMemoryWarning:) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillChangeStatusBarOrientation:) name:UIApplicationWillChangeStatusBarOrientationNotification object:nil];
}

- (id)initWithCoder:(NSCoder*)coder
{
	if (self = [super initWithCoder:coder]) {
		[self setup];
	}
	return self;
}

- (id)initWithFrame:(CGRect)frame
{
	if (self = [super initWithFrame:frame]) {
		[self setup];
	}
	return self;
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];  // for UIApplicationDidReceiveMemoryWarningNotification
}

- (void)applicationDidReceiveMemoryWarning:(NSNotification*)notification
{
	[self reloadAllEvents];
}

- (void)applicationWillChangeStatusBarOrientation:(NSNotification*)notification
{
    [self endInteraction];
    
    // cancel eventual pan gestures
    self.timedEventsView.panGestureRecognizer.enabled = NO;
    self.timedEventsView.panGestureRecognizer.enabled = YES;
    
}

#pragma mark - Layout

// public
- (void)setNumberOfVisibleDays:(NSUInteger)numberOfVisibleDays
{
	NSAssert(numberOfVisibleDays > 0, @"numberOfVisibleDays in day planner view cannot be set to 0");
	
	if (_numberOfVisibleDays != numberOfVisibleDays) {
		NSDate* date = self.visibleDays.start;
        
        _numberOfVisibleDays = numberOfVisibleDays;
        
        if (self.dateRange && [self.dateRange components:NSCalendarUnitDay forCalendar:self.calendar].day < numberOfVisibleDays)
            return;
        
        [self reloadCollectionViews];
        [self scrollToDate:date options:MGCDayPlannerScrollDate animated:NO];
	}
}

// public
- (void)setHourSlotHeight:(CGFloat)hourSlotHeight
{
    CGFloat yCenterOffset = self.timeScrollView.contentOffset.y + self.timeScrollView.bounds.size.height / 2.;
    NSTimeInterval ti = [self timeFromOffset:yCenterOffset rounding:0];
   
    _hourSlotHeight = fminf(fmaxf(MGCAlignedFloat(hourSlotHeight), kMinHourSlotHeight), kMaxHourSlotHeight);
    
    [self.dayColumnsView.collectionViewLayout invalidateLayout];
    
    self.timedEventsViewLayout.dayColumnSize = self.dayColumnSize;
    self.timedEventsViewLayout.heightLoadMore = self.heightLoadMore;
    [self.timedEventsViewLayout invalidateLayout];
    
    self.timeRowsView.hourSlotHeight = _hourSlotHeight;
    self.timeScrollView.contentSize = CGSizeMake(self.bounds.size.width, self.dayColumnSize.height+_heightLoadMore);
    self.timeRowsView.frame = CGRectMake(0, 0, self.timeScrollView.contentSize.width, self.timeScrollView.contentSize.height);
    
    CGFloat yOffset = [self offsetFromTime:ti rounding:0] - self.timeScrollView.bounds.size.height / 2.;
    yOffset = fmaxf(0, fminf(yOffset, self.timeScrollView.contentSize.height - self.timeScrollView.bounds.size.height));

    self.timeScrollView.contentOffset = CGPointMake(0, yOffset);
    self.timedEventsView.contentOffset = CGPointMake(self.timedEventsView.contentOffset.x, yOffset);
}

// public
- (CGSize)dayColumnSize
{
 	CGFloat height = self.hourSlotHeight * _sizeEventInSection + 2 * self.eventsViewInnerMargin;
	
	// if the number of days in dateRange is less than numberOfVisibleDays, spread the days over the view
	NSUInteger numberOfDays = MIN(self.numberOfVisibleDays, self.numberOfLoadedDays);
    CGFloat width = (self.bounds.size.width - self.timeColumnWidth) / numberOfDays;
	
	return MGCAlignedSizeMake(width, height);
}

// public
- (NSCalendar*)calendar
{
	if (_calendar == nil) {
		_calendar = [NSCalendar currentCalendar];
	}
	return _calendar;
}

// public
- (void)setDateRange:(MGCDateRange*)dateRange
{
	if (dateRange != _dateRange && ![dateRange isEqual:_dateRange]) {
		NSDate *firstDate = self.visibleDays.start;
		
		_dateRange = nil;
	
		if (dateRange) {
			
			// adjust start and end date of new range on day boundaries
			NSDate *start = [self.calendar mgc_startOfDayForDate:dateRange.start];
			NSDate *end = [self.calendar mgc_startOfDayForDate:dateRange.end];
			_dateRange = [MGCDateRange dateRangeWithStart:start end:end];
			
			// adjust startDate so that it falls inside new range
			if (![_dateRange includesDateRange:self.loadedDaysRange]) {
				self.startDate = _dateRange.start;
			}
			
			if (![_dateRange containsDate:firstDate]) {
				firstDate = [NSDate date];
				if (![_dateRange containsDate:firstDate]) {
					firstDate = _dateRange.start;
				}
			}
		}
		
		[self reloadCollectionViews];
		[self scrollToDate:firstDate options:MGCDayPlannerScrollDate animated:NO];
	}
}

// public
- (MGCDateRange*)visibleDays
{
    CGFloat dayWidth = self.dayColumnSize.width;
	
	NSUInteger first = floorf(self.timedEventsView.contentOffset.x / dayWidth);
	NSDate *firstDay = [self dateFromDayOffset:first];
	if (self.dateRange && [firstDay compare:self.dateRange.start] == NSOrderedAscending)
		firstDay = self.dateRange.start;

	// since the day column width is rounded, there can be a difference of a few points between
	// the right side of the view bounds and the limit of the last column, causing last visible day
	// to be one more than expected. We have to take this in account
	CGFloat diff = self.timedEventsView.bounds.size.width - self.dayColumnSize.width * self.numberOfVisibleDays;

	NSUInteger last = ceilf((CGRectGetMaxX(self.timedEventsView.bounds) - diff) / dayWidth);
	NSDate *lastDay = [self dateFromDayOffset:last];
	if (self.dateRange && [lastDay compare:self.dateRange.end] != NSOrderedAscending)
		lastDay = self.dateRange.end;

	return [MGCDateRange dateRangeWithStart:firstDay end:lastDay];
}

// public
- (NSTimeInterval)firstVisibleTime
{
    NSTimeInterval ti = [self timeFromOffset:self.timedEventsView.contentOffset.y rounding:0];
    return fmax(self.sizeEventInSection * 3600., ti);
}

// public
- (NSTimeInterval)lastVisibleTime
{
    NSTimeInterval ti = [self timeFromOffset:CGRectGetMaxY(self.timedEventsView.bounds) rounding:0];
    return fmin(self.sizeEventInSection * 3600., ti);
}

// public
- (void)setSizeEventInSection:(NSUInteger)sizeEventInSection
{
    _sizeEventInSection = sizeEventInSection;
    
    [self.dimmedTimeRangesCache removeAllObjects];
    
    self.timedEventsViewLayout.dayColumnSize = self.dayColumnSize;
     self.timedEventsViewLayout.heightLoadMore = self.heightLoadMore;
    [self.timedEventsViewLayout invalidateLayout];

    self.timeRowsView.numColumn = self.sizeEventInSection;
    self.timeScrollView.contentSize = CGSizeMake(self.bounds.size.width, self.dayColumnSize.height+_heightLoadMore);
    self.timeRowsView.frame = CGRectMake(0, 0, self.timeScrollView.contentSize.width, self.timeScrollView.contentSize.height);
    
    [self.ShiftLoadMoreView removeFromSuperview];
    self.ShiftLoadMoreView.frame = CGRectMake(0, self.dayColumnSize.height,self.bounds.size.width , _heightLoadMore);
    [self.timeScrollView addSubview:_ShiftLoadMoreView];
}

// public
- (void)setDateFormat:(NSString*)dateFormat
{
	if (dateFormat != _dateFormat || ![dateFormat isEqualToString:_dateFormat]) {
		_dateFormat = [dateFormat copy];
		[self.dayColumnsView reloadData];
	}
}

// public
- (void)setDaySeparatorsColor:(UIColor *)daySeparatorsColor
{
    _daySeparatorsColor = daySeparatorsColor;
    [self.dayColumnsView reloadData];
}

// public
- (void)setTimeSeparatorsColor:(UIColor *)timeSeparatorsColor
{
    _timeSeparatorsColor = timeSeparatorsColor;
    self.timeRowsView.timeColor = timeSeparatorsColor;
    [self.timeRowsView setNeedsDisplay];
}

// public
- (void)setCurrentTimeColor:(UIColor *)currentTimeColor
{
    _currentTimeColor = currentTimeColor;
    self.timeRowsView.currentTimeColor = currentTimeColor;
    [self.timeRowsView setNeedsDisplay];
}

// public
- (void)setListHeaderCell:(NSMutableDictionary *)listHeaderCell
{
    _listHeaderCell = listHeaderCell;
    [self.dayColumnsView reloadData];
}

// public
- (void)setDimmingColor:(UIColor *)dimmingColor
{
    _dimmingColor = dimmingColor;
    for (UIView *v in [self.timedEventsView visibleSupplementaryViewsOfKind:DimmingViewKind]) {
        v.backgroundColor = dimmingColor;
    }
}

-(void)setMaxCellVisible:(NSInteger)maxCellVisible{
    _maxCellVisible = maxCellVisible;
     _dayHeaderHeight = _maxCellVisible*_heightHeaderDayCell + _fontSizeNameHeaderDay+2+10;
    [self.dayColumnsView reloadData];
    [self reloadAllEvents];
}
#pragma mark - Private properties

// startDate is the first currently loaded day in the collection views - time is set to 00:00
- (NSDate*)startDate
{
	if (_startDate == nil) {
		_startDate = [self.calendar mgc_startOfDayForDate:[NSDate date]];
		
		if (self.dateRange && ![self.dateRange containsDate:_startDate]) {
			_startDate = self.dateRange.start;
		}
	}
	return _startDate;
}

- (void)setStartDate:(NSDate*)startDate
{
	startDate = [self.calendar mgc_startOfDayForDate:startDate];
	
	NSAssert([startDate compare:self.dateRange.start] !=  NSOrderedAscending, @"start date not in the scrollable date range");
	NSAssert([startDate compare:self.maxStartDate] != NSOrderedDescending, @"start date not in the scrollable date range");

	_startDate = startDate;
	
	//NSLog(@"Loaded days range: %@", self.loadedDaysRange);
}

- (NSDate*)maxStartDate
{
	NSDate *date = nil;
	
	if (self.dateRange) {
		NSDateComponents *comps = [NSDateComponents new];
		comps.day = -(2 * kDaysLoadingStep + 1) * self.numberOfVisibleDays;
		date = [self.calendar dateByAddingComponents:comps toDate:self.dateRange.end options:0];
		
		if ([date compare:self.dateRange.start] == NSOrderedAscending) {
			date = self.dateRange.start;
		}
	}
	return date;
}

- (NSUInteger)numberOfLoadedDays
{
	NSUInteger numDays = (2 * kDaysLoadingStep + 1) * self.numberOfVisibleDays;
	if (self.dateRange) {
		NSInteger diff = [self.dateRange components:NSCalendarUnitDay forCalendar:self.calendar].day;
		numDays = MIN(numDays, diff);  // cannot load more than the total number of scrollable days
	}
	return numDays;
}

- (MGCDateRange*)loadedDaysRange
{
	NSDateComponents *comps = [NSDateComponents new];
	comps.day = self.numberOfLoadedDays;
	NSDate *endDate = [self.calendar dateByAddingComponents:comps toDate:self.startDate options:0];
	return [MGCDateRange dateRangeWithStart:self.startDate end:endDate];
}

// first fully visible day (!= visibleDays.start)
- (NSDate*)firstVisibleDate
{
	CGFloat xOffset = self.timedEventsView.contentOffset.x;
	NSUInteger section = ceilf(xOffset / self.dayColumnSize.width);
	return [self dateFromDayOffset:section];
}

#pragma mark - Utilities

// dayOffset is the offset from the first loaded day in the view (ie startDate)
- (CGFloat)xOffsetFromDayOffset:(NSInteger)dayOffset
{
	return (dayOffset * self.dayColumnSize.width);
}

// dayOffset is the offset from the first loaded day in the view (ie startDate)
- (NSDate*)dateFromDayOffset:(NSInteger)dayOffset
{
	NSDateComponents *comp = [NSDateComponents new];
	comp.day = dayOffset;
	return [self.calendar dateByAddingComponents:comp toDate:self.startDate options:0];
}

// returns the day offset from the first loaded day in the view (ie startDate)
- (NSInteger)dayOffsetFromDate:(NSDate*)date
{
	NSAssert(date, @"dayOffsetFromDate: was passed nil date");
	
	NSDateComponents *comps = [self.calendar components:NSCalendarUnitDay fromDate:self.startDate toDate:date options:0];
	return comps.day;
}

// returns the time interval corresponding to a vertical offset in the timedEventsView coordinates,
// rounded according to given parameter (in minutes)
- (NSTimeInterval)timeFromOffset:(CGFloat)yOffset rounding:(NSUInteger)rounding
{
	rounding = MAX(rounding % 60, 1);
    
    CGFloat hour = fmax(0, (yOffset - self.eventsViewInnerMargin) / self.hourSlotHeight);
   	NSTimeInterval ti = roundf((hour * 3600) / (rounding * 60)) * (rounding * 60);
    
 	return ti;
}

// returns the vertical offset in the timedEventsView coordinates corresponding to given time interval
// previously rounded according to parameter (in minutes)
- (CGFloat)offsetFromTime:(NSTimeInterval)ti rounding:(NSUInteger)rounding
{
	rounding = MAX(rounding % 60, 1);
	ti = roundf(ti / (rounding * 60)) * (rounding * 60);
	CGFloat hour = ti / 3600.;
	return MGCAlignedFloat(hour * self.hourSlotHeight + self.eventsViewInnerMargin);
}

- (CGFloat)offsetFromDate:(NSDate*)date
{
    NSDateComponents *comp = [self.calendar components:(NSCalendarUnitHour|NSCalendarUnitMinute) fromDate:date];
      CGFloat y = roundf((comp.hour + comp.minute / 60.) * self.hourSlotHeight);
    return MGCAlignedFloat(y);
}

// returns the offset for a given event date and type in self coordinates
- (CGPoint)offsetFromDate:(NSDate*)date eventType:(MGCEventType)type
{
    CGFloat x = [self xOffsetFromDayOffset:[self dayOffsetFromDate:date]];
    NSTimeInterval ti = [date timeIntervalSinceDate:[self.calendar mgc_startOfDayForDate:date]];
    CGFloat y = [self offsetFromTime:ti rounding:1];
    CGPoint pt = CGPointMake(x, y);
    return [self convertPoint:pt fromView:self.timedEventsView];
}

#pragma mark - Locating days and events

// public
- (NSDate*)dateAtPoint:(CGPoint)point rounded:(BOOL)rounded
{
	if (self.dayColumnsView.contentSize.width == 0) return nil;
	
	CGPoint ptDayColumnsView = [self convertPoint:point toView:self.dayColumnsView];
	NSIndexPath *dayPath = [self.dayColumnsView indexPathForItemAtPoint:ptDayColumnsView];
	
	if (dayPath) {
		// get the day/month/year portion of the date
		NSDate *date = [self dateFromDayOffset:dayPath.section];

		// get the time portion
		CGPoint ptTimedEventsView = [self convertPoint:point toView:self.timedEventsView];
		if ([self.timedEventsView pointInside:ptTimedEventsView withEvent:nil]) {
            // max time for is 23:59
			NSTimeInterval ti = fminf([self timeFromOffset:ptTimedEventsView.y rounding:15], 24 * 3600. - 60);
			date = [date dateByAddingTimeInterval:ti];
		}
		return date;
	}
	return nil;
}

// public
- (MGCEventView*)eventViewAtPoint:(CGPoint)point type:(MGCEventType*)type index:(NSUInteger*)index date:(NSDate**)date
{
	CGPoint ptTimedEventsView = [self convertPoint:point toView:self.timedEventsView];
	
	if ([self.timedEventsView pointInside:ptTimedEventsView withEvent:nil]) {
		NSIndexPath *path = [self.timedEventsView indexPathForItemAtPoint:ptTimedEventsView];
		if (path) {
			MGCEventCell *cell = (MGCEventCell*)[self.timedEventsView cellForItemAtIndexPath:path];
			if (type) *type = MGCTimedEventType;
			if (index) *index = path.item;
			if (date) *date = [self dateFromDayOffset:path.section];
			return cell.eventView;
		}
	}
	return nil;
}

// public
- (MGCEventView*)eventViewOfType:(MGCEventType)type atIndex:(NSUInteger)index date:(NSDate*)date
{
	NSAssert(date, @"eventViewOfType:atIndex:date: was passed nil date");
	
	NSUInteger section = [self dayOffsetFromDate:date];
	NSIndexPath *indexPath = [NSIndexPath indexPathForItem:index inSection:section];
	
	return [[self collectionViewCellForEventOfType:type atIndexPath:indexPath] eventView];
}

#pragma mark - Navigation

// public
-(void)scrollToDate:(NSDate*)date options:(MGCDayPlannerScrollType)options animated:(BOOL)animated
{
	NSAssert(date, @"scrollToDate:date: was passed nil date");
	
	if (self.dateRange && ![self.dateRange containsDate:date]) {
		[NSException raise:@"Invalid parameter" format:@"date %@ is not in range %@ for this day planner view", date, self.dateRange];
	}
	
	// if scrolling is already happening, let it end properly
	if (self.controllingScrollView) return;
	
	NSDate *firstVisible = date;
	NSDate *maxScrollable = [self maxScrollableDate];
	if (maxScrollable != nil && [firstVisible compare:maxScrollable] == NSOrderedDescending) {
		firstVisible = maxScrollable;
	}
	
	NSDate *dayStart = [self.calendar mgc_startOfDayForDate:firstVisible];
    self.scrollTargetDate = dayStart;
    
	NSTimeInterval ti = [date timeIntervalSinceDate:dayStart];
	
    CGFloat y = [self offsetFromTime:ti rounding:0];
	y = fmaxf(fminf(y, MGCAlignedFloat(self.timedEventsView.contentSize.height - self.timedEventsView.bounds.size.height)), 0);
	CGFloat x = [self xOffsetFromDayOffset:[self dayOffsetFromDate:dayStart]];

	CGPoint offset = self.timedEventsView.contentOffset;

	ShiftDayPlannerView * __weak weakSelf = self;
	dispatch_block_t completion = ^{
		weakSelf.userInteractionEnabled = YES;
		if (!animated && [weakSelf.delegate respondsToSelector:@selector(dayPlannerView:didScroll:)]) {
			[weakSelf.delegate dayPlannerView:weakSelf didScroll:options];
		}
	};
	
	if (options == MGCDayPlannerScrollTime) {
		self.userInteractionEnabled = NO;
		offset.y = y;
		[self setTimedEventsViewContentOffset:offset animated:animated completion:completion];
	}
	else if (options == MGCDayPlannerScrollDate) {
		self.userInteractionEnabled = NO;
		offset.x = x;
		[self setTimedEventsViewContentOffset:offset animated:animated completion:completion];
	}
	else if (options == MGCDayPlannerScrollDateTime) {
		self.userInteractionEnabled = NO;
		offset.x = x;
		[self setTimedEventsViewContentOffset:offset animated:animated completion:^(void){
			CGPoint offset = CGPointMake(weakSelf.timedEventsView.contentOffset.x, y);
			[weakSelf setTimedEventsViewContentOffset:offset animated:animated completion:completion];
		}];
	}
}

// public
- (void)pageForwardAnimated:(BOOL)animated date:(NSDate**)date
{
	NSDate *next = [self nextDateForPagingAfterDate:self.visibleDays.start];
	if (date != nil)
		*date = next;
	[self scrollToDate:next options:MGCDayPlannerScrollDate animated:animated];
}

// public
- (void)pageBackwardsAnimated:(BOOL)animated date:(NSDate**)date
{
	NSDate *prev = [self prevDateForPagingBeforeDate:self.firstVisibleDate];
	if (date != nil)
		*date = prev;
	[self scrollToDate:prev options:MGCDayPlannerScrollDate animated:animated];
}

// returns the latest date to be shown on the left side of the view,
// nil if the day planner has no date range.
- (NSDate*)maxScrollableDate
{
    if (self.dateRange != nil) {
        NSUInteger numVisible = MIN(self.numberOfVisibleDays, [self.dateRange components:NSCalendarUnitDay forCalendar:self.calendar].day);
		NSDateComponents *comps = [NSDateComponents new];
		comps.day = -numVisible;
		return [self.calendar dateByAddingComponents:comps toDate:self.dateRange.end options:0];
	}
	return nil;
}

// retuns the earliest date to be shown on the left side of the view,
// nil if the day planner has no date range.
- (NSDate*)minScrollableDate
{
	return self.dateRange != nil ? self.dateRange.start : nil;
}

// if the view shows at least 7 days, returns the next start of a week after date,
// otherwise returns date plus the number of visible days, within the limits of the view day range
- (NSDate*)nextDateForPagingAfterDate:(NSDate*)date
{
	NSAssert(date, @"nextPageForPagingAfterDate: was passed nil date");
	
	NSDate *nextDate;
	if (self.numberOfVisibleDays >= 7) {
		nextDate = [self.calendar mgc_nextStartOfWeekForDate:date];
	}
	else {
		NSDateComponents *comps = [NSDateComponents new];
		comps.day = self.numberOfVisibleDays;
		nextDate = [self.calendar dateByAddingComponents:comps toDate:date options:0];
	}
	
	NSDate *maxScrollable = [self maxScrollableDate];
	if (maxScrollable != nil && [nextDate compare:maxScrollable] == NSOrderedDescending) {
		nextDate = maxScrollable;
	}
	return nextDate;
}

// If the view shows at least 7 days, returns the previous start of a week before date,
// otherwise returns date minus the number of visible days, within the limits of the view day range
- (NSDate*)prevDateForPagingBeforeDate:(NSDate*)date
{
	NSAssert(date, @"prevDateForPagingBeforeDate: was passed nil date");
	
	NSDate *prevDate;
	if (self.numberOfVisibleDays >= 7) {
		prevDate = [self.calendar mgc_startOfWeekForDate:date];
		if ([prevDate isEqualToDate:date]) {
			NSDateComponents* comps = [NSDateComponents new];
			comps.day = -7;
			prevDate = [self.calendar dateByAddingComponents:comps toDate:date options:0];
		}
	}
	else {
		NSDateComponents *comps = [NSDateComponents new];
		comps.day = -self.numberOfVisibleDays;
		prevDate = [self.calendar dateByAddingComponents:comps toDate:date options:0];
	}
	
	NSDate *minScrollable = [self minScrollableDate];
	if (minScrollable != nil && [prevDate compare:minScrollable] == NSOrderedAscending) {
		prevDate = minScrollable;
	}
	return prevDate;
	
}

#pragma mark - Subviews

- (UICollectionView*)timedEventsView
{
    if (!_timedEventsView) {
		_timedEventsView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:self.timedEventsViewLayout];
		_timedEventsView.backgroundColor = [UIColor clearColor];
		_timedEventsView.dataSource = self;
		_timedEventsView.delegate = self;
		_timedEventsView.showsVerticalScrollIndicator = NO;
		_timedEventsView.showsHorizontalScrollIndicator = NO;
		_timedEventsView.scrollsToTop = NO;
		_timedEventsView.decelerationRate = UIScrollViewDecelerationRateFast;
		_timedEventsView.allowsSelection = NO;
		_timedEventsView.directionalLockEnabled = YES;
		
		[_timedEventsView registerClass:MGCEventCell.class forCellWithReuseIdentifier:EventCellReuseIdentifier];
        [_timedEventsView registerClass:UICollectionReusableView.class forSupplementaryViewOfKind:DimmingViewKind withReuseIdentifier:DimmingViewReuseIdentifier];
		
		UITapGestureRecognizer *tap = [UITapGestureRecognizer new];
		[tap addTarget:self action:@selector(handleTap:)];
		[_timedEventsView addGestureRecognizer:tap];
	}
	return _timedEventsView;
}

- (UICollectionView*)dayColumnsView
{
	if (!_dayColumnsView) {
        MGCDayColumnViewFlowLayout *layout = [MGCDayColumnViewFlowLayout new];
		layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
		layout.minimumInteritemSpacing = 0;
		layout.minimumLineSpacing = 0;
        
		_dayColumnsView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
		_dayColumnsView.backgroundColor = [UIColor clearColor];
		_dayColumnsView.dataSource = self;
		_dayColumnsView.delegate = self;
		_dayColumnsView.showsHorizontalScrollIndicator = NO;
		_dayColumnsView.decelerationRate = UIScrollViewDecelerationRateFast;
		_dayColumnsView.scrollEnabled = NO;
		_dayColumnsView.allowsSelection = NO;
		
		[_dayColumnsView registerClass:ShiftDayColumnCell.class forCellWithReuseIdentifier:DayColumnCellReuseIdentifier];
	}
	return _dayColumnsView;
}

-(ShiftLoadMoreView*) ShiftLoadMoreView{
    if(!_ShiftLoadMoreView) {
        _ShiftLoadMoreView = [[ShiftLoadMoreView alloc] initWithFrame:CGRectZero];
    }
    return _ShiftLoadMoreView;
}

-(ShiftButtonSelect*) btnSelect{
    if(!_btnSelect) {
        _btnSelect = [[ShiftButtonSelect alloc] initWithFrame:CGRectZero];
    }
    return _btnSelect;
}

-(UIView*) speratorHoziView{
    if(!_speratorHoziView) {
        _speratorHoziView = [[UIView alloc] initWithFrame:CGRectZero];
    }
    return _speratorHoziView;
}

-(UIView*) speratorVeticalView{
    if(!_speratorVeticalView) {
        _speratorVeticalView = [[UIView alloc] initWithFrame:CGRectZero];
    }
    return _speratorVeticalView;
}

- (UIScrollView*)timeScrollView
{
	if (!_timeScrollView) {
		_timeScrollView = [[UIScrollView alloc]initWithFrame:CGRectZero];
		_timeScrollView.backgroundColor = [UIColor clearColor];
		_timeScrollView.delegate = self;
		_timeScrollView.showsVerticalScrollIndicator = NO;
		_timeScrollView.decelerationRate = UIScrollViewDecelerationRateFast;
		_timeScrollView.scrollEnabled = NO;
		
		_timeRowsView = [[ShiftTimeRowsView alloc]initWithFrame:CGRectZero];
        _timeRowsView.delegate = self;
        _timeRowsView.timeColor = self.timeSeparatorsColor;
        _timeRowsView.currentTimeColor = self.currentTimeColor;
		_timeRowsView.hourSlotHeight = self.hourSlotHeight;
        _timeRowsView.numColumn = self.sizeEventInSection;
		_timeRowsView.insetsHeight = self.eventsViewInnerMargin;
		_timeRowsView.timeColumnWidth = self.timeColumnWidth;
		_timeRowsView.contentMode = UIViewContentModeRedraw;
		[_timeScrollView addSubview:_timeRowsView];
	}
	return _timeScrollView;
}

#pragma mark - Layouts

- (ShiftTimedEventsViewLayout*)timedEventsViewLayout
{
	if (!_timedEventsViewLayout) {
		_timedEventsViewLayout = [ShiftTimedEventsViewLayout new];
		_timedEventsViewLayout.delegate = self;
		_timedEventsViewLayout.dayColumnSize = self.dayColumnSize;
        _timedEventsViewLayout.coveringType = TimedEventCoveringTypeClassic;
	}
	return _timedEventsViewLayout;
}

#pragma mark - Event view manipulation

- (void)registerClass:(Class)viewClass forEventViewWithReuseIdentifier:(NSString*)identifier
{
	[self.reuseQueue registerClass:viewClass forObjectWithReuseIdentifier:identifier];
}

- (MGCEventView*)dequeueReusableViewWithIdentifier:(NSString*)identifier forEventOfType:(MGCEventType)type atIndex:(NSUInteger)index date:(NSDate*)date
{
	return (MGCEventView*)[self.reuseQueue dequeueReusableObjectWithReuseIdentifier:identifier];
}

#pragma mark - Selection

- (void)handleTap:(UITapGestureRecognizer*)gesture
{
	if (gesture.state == UIGestureRecognizerStateEnded)
	{
		[self deselectEventWithDelegate:YES]; // deselect previous
		
		UICollectionView *view = (UICollectionView*)gesture.view;
		CGPoint pt = [gesture locationInView:view];
		
		NSIndexPath *path = [view indexPathForItemAtPoint:pt];
		if (path)  // a cell was touched
		{
			NSDate *date = [self dateFromDayOffset:path.section];
            MGCEventType type = MGCTimedEventType;
			
			[self selectEventWithDelegate:YES type:type atIndex:path.item date:date];
		}
	}
}

// public
- (MGCEventView*)selectedEventView
{
	if (self.selectedCellIndexPath) {
		MGCEventCell *cell = [self collectionViewCellForEventOfType:self.selectedCellType atIndexPath:self.selectedCellIndexPath];
		return cell.eventView;
	}
	return nil;
}

// tellDelegate is used to distinguish between user selection (touch) where delegate is informed,
// and programmatically selected events where delegate is not informed
-(void)selectEventWithDelegate:(BOOL)tellDelegate type:(MGCEventType)type atIndex:(NSUInteger)index date:(NSDate*)date
{
	[self deselectEventWithDelegate:tellDelegate];
	
	if (self.allowsSelection) {
		NSInteger section = [self dayOffsetFromDate:date];
		NSIndexPath *path = [NSIndexPath indexPathForItem:index inSection:section];
		
		MGCEventCell *cell = [self collectionViewCellForEventOfType:type atIndexPath:path];
		if (cell)
		{
			BOOL shouldSelect = YES;
			if (tellDelegate && [self.delegate respondsToSelector:@selector(dayPlannerView:shouldSelectEventOfType:atIndex:date:)]) {
				shouldSelect = [self.delegate dayPlannerView:self shouldSelectEventOfType:type atIndex:index date:date];
			}

			if (shouldSelect) {
				cell.selected = YES;
				self.selectedCellIndexPath = path;
				self.selectedCellType = type;
				
				if (tellDelegate && [self.delegate respondsToSelector:@selector(dayPlannerView:didSelectEventOfType:atIndex:date:)]) {
					[self.delegate dayPlannerView:self didSelectEventOfType:type atIndex:path.item date:date];
				}
			}
		}
	}
}

// public
- (void)selectEventOfType:(MGCEventType)type atIndex:(NSUInteger)index date:(NSDate*)date
{
	[self selectEventWithDelegate:NO type:type atIndex:index date:date];
}

// tellDelegate is used to distinguish between user deselection (touch) where delegate is informed,
// and programmatically deselected events where delegate is not informed
- (void)deselectEventWithDelegate:(BOOL)tellDelegate
{
	if (self.allowsSelection && self.selectedCellIndexPath)
	{
		MGCEventCell *cell = [self collectionViewCellForEventOfType:self.selectedCellType atIndexPath:self.selectedCellIndexPath];
		cell.selected = NO;
		
		NSDate *date = [self dateFromDayOffset:self.selectedCellIndexPath.section];
		if (tellDelegate && [self.delegate respondsToSelector:@selector(dayPlannerView:didDeselectEventOfType:atIndex:date:)]) {
			[self.delegate dayPlannerView:self didDeselectEventOfType:self.selectedCellType atIndex:self.selectedCellIndexPath.item date:date];
		}
		
		self.selectedCellIndexPath = nil;
	}
}

// public
- (void)deselectEvent
{
	[self deselectEventWithDelegate:NO];
}

#pragma mark - Event views interaction

// For non modifiable events like holy days, birthdays... for which delegate method
// shouldStartMovingEventOfType returns NO, we bounce animate the cell when user tries to move it
- (void)bounceAnimateCell:(MGCEventCell*)cell
{
	CGRect frame = cell.frame;
	
	[UIView animateWithDuration:0.2 animations:^{
		[UIView setAnimationRepeatCount:2];
		cell.frame = CGRectInset(cell.frame, -4, -2);
	} completion:^(BOOL finished){
		cell.frame = frame;
	}];
}

- (void)endInteraction
{
	if (self.interactiveCell) {
		self.interactiveCell.hidden = YES;
		[self.interactiveCell removeFromSuperview];
		self.interactiveCell = nil;
        
        [self.dragTimer invalidate];
        self.dragTimer = nil;
	}
	self.interactiveCellTouchPoint = CGPointZero;
	self.timeRowsView.timeMark = 0;
}

#pragma mark - Reloading content

// this is called whenever we recenter the views during scrolling
// or when the number of visible days or the date range changes
- (void)reloadCollectionViews
{
	//NSLog(@"reloadCollectionsViews");
	
	[self deselectEventWithDelegate:YES];
    
    CGSize dayColumnSize = self.dayColumnSize;
    
    self.timedEventsViewLayout.dayColumnSize = dayColumnSize;
    self.timedEventsViewLayout.heightLoadMore = self.heightLoadMore;
    
    [self.dayColumnsView reloadData];
	[self.timedEventsView reloadData];

    if (!self.controllingScrollView) {  // only if we're not scrolling
       dispatch_async(dispatch_get_main_queue(), ^{ [self setupSubviews]; });
    }
}

// public
- (void)reloadAllEvents
{
	//NSLog(@"reloadAllEvents");
	
	[self deselectEventWithDelegate:YES];
	[self.timedEventsView reloadData];
	
	if (!self.controllingScrollView) {
		dispatch_async(dispatch_get_main_queue(), ^{ [self setupSubviews]; });
	}
	
	[self.loadedDaysRange enumerateDaysWithCalendar:self.calendar usingBlock:^(NSDate *date, BOOL *stop) {
		[self refreshEventMarkForColumnAtDate:date];
	}];
}

- (void)refreshEventMarkForColumnAtDate:(NSDate*)date
{
	NSInteger section = [self dayOffsetFromDate:date];
	NSIndexPath *path = [NSIndexPath indexPathForItem:0 inSection:section];
	ShiftDayColumnCell *cell = (ShiftDayColumnCell*)[self.dayColumnsView cellForItemAtIndexPath:path];
	if (cell) {
		NSUInteger count = [self numberOfTimedEventsAtDate:date];
		if (count > 0) {
			cell.accessoryTypes |= ShiftDayColumnCellAccessoryDot;
		}
		else {
			cell.accessoryTypes &= ~ShiftDayColumnCellAccessoryDot;
		}
	}
}

// public
- (void)reloadEventsAtDate:(NSDate*)date
{
	//NSLog(@"reloadEventsAtDate %@", date);

	[self deselectEventWithDelegate:YES];
	
	if ([self.loadedDaysRange containsDate:date]) {
		if (!self.controllingScrollView) {
			// only if we're not scrolling
			[self setupSubviews];
		}
        NSInteger section = [self dayOffsetFromDate:date];
        
        // for some reason, reloadSections: does not work properly. See comment for ignoreNextInvalidation
        self.timedEventsViewLayout.ignoreNextInvalidation = YES; 
        [self.timedEventsView reloadData];
		
        ShiftTimedEventsViewLayoutInvalidationContext *context = [ShiftTimedEventsViewLayoutInvalidationContext new];
        context.invalidatedSections = [NSIndexSet indexSetWithIndex:section];
        [self.timedEventsView.collectionViewLayout invalidateLayoutWithContext:context];

		[self refreshEventMarkForColumnAtDate:date];
	}
}

// public
- (void)reloadDimmedTimeRanges
{
    [self.dimmedTimeRangesCache removeAllObjects];
    
    ShiftTimedEventsViewLayoutInvalidationContext *context = [ShiftTimedEventsViewLayoutInvalidationContext new];
    context.invalidatedSections = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, self.numberOfLoadedDays)];
    context.invalidateEventCells = NO;
    context.invalidateDimmingViews = YES;
    [self.timedEventsView.collectionViewLayout invalidateLayoutWithContext:context];
}


// public
- (BOOL)setActivityIndicatorVisible:(BOOL)visible forDate:(NSDate*)date
{
	if (visible) {
		[self.loadingDays addObject:date];
	}
	else {
		[self.loadingDays removeObject:date];
	}
	
	if ([self.loadedDaysRange containsDate:date]) {
		NSIndexPath *path = [NSIndexPath indexPathForItem:0 inSection:[self dayOffsetFromDate:date]];
		ShiftDayColumnCell *cell = (ShiftDayColumnCell*)[self.dayColumnsView cellForItemAtIndexPath:path];
		if (cell) {
			[cell setActivityIndicatorVisible:visible];
			return YES;
		}
	}
	return NO;
}

- (void)changeClick:(NSInteger) currentIndex withDate:(NSDate*) date{
    [self.timeRowsView setCurrentIndex:currentIndex];
    _indexDate = [self.calendar mgc_startOfDayForDate:date];
    [self.dayColumnsView reloadData];
}

- (void)setupSubviews
{
    CGFloat allDayEventsViewHeight = 2;
	CGFloat timedEventViewTop = self.dayHeaderHeight + allDayEventsViewHeight;
	CGFloat timedEventsViewWidth = self.bounds.size.width - self.timeColumnWidth;
	CGFloat timedEventsViewHeight = self.bounds.size.height - (self.dayHeaderHeight + allDayEventsViewHeight);
	
	//self.backgroundView.frame = CGRectMake(0, self.dayHeaderHeight, self.bounds.size.width, self.bounds.size.height - self.dayHeaderHeight);
	self.backgroundView.frame = CGRectMake(self.timeColumnWidth, self.dayHeaderHeight + allDayEventsViewHeight, timedEventsViewWidth, timedEventsViewHeight);
	self.backgroundView.frame = CGRectMake(0, timedEventViewTop, self.bounds.size.width, timedEventsViewHeight);
	if (!self.backgroundView.superview) {
		[self addSubview:self.backgroundView];
	}
    //add button
    self.btnSelect.frame = CGRectMake(0, 0, self.timeColumnWidth, self.dayHeaderHeight);
    [self addSubview:_btnSelect];
    __weak typeof(self) weakSelf = self;
    self.btnSelect.sellectClick = ^{
        [weakSelf.delegate dayPlannerViewClickShiftButtonSelect];
    };
    // add speratorHozi
    self.speratorHoziView.frame =CGRectMake(0, self.dayHeaderHeight, self.timeColumnWidth, 0.5);
    self.speratorHoziView.backgroundColor = [UIColor lightGrayColor];
    if(!self.speratorHoziView.superview){
        [self addSubview:self.speratorHoziView];
    }
    // add speratorVetical
    self.speratorVeticalView.frame = CGRectMake(self.timeColumnWidth, 0, 0.5, self.dayHeaderHeight);
    self.speratorVeticalView.backgroundColor = [UIColor lightGrayColor];
    [self addSubview:self.speratorVeticalView];
    
    self.timedEventsView.frame = CGRectMake(self.timeColumnWidth, timedEventViewTop, timedEventsViewWidth, timedEventsViewHeight);
    if (!self.timedEventsView.superview) {
        [self addSubview:self.timedEventsView];
    }

	self.timeScrollView.contentSize = CGSizeMake(self.bounds.size.width, self.dayColumnSize.height+_heightLoadMore);
	self.timeRowsView.frame = CGRectMake(0, 0, self.timeScrollView.contentSize.width, self.dayColumnSize.height);
    
    self.ShiftLoadMoreView.frame = CGRectMake(0, self.dayColumnSize.height,self.bounds.size.width , _heightLoadMore);
    [self.timeScrollView addSubview:_ShiftLoadMoreView];
	self.timeScrollView.frame = CGRectMake(0, timedEventViewTop, self.bounds.size.width, timedEventsViewHeight);
    if (!self.timeScrollView.superview) {
        [self addSubview:self.timeScrollView];
    }
	
	self.timeRowsView.showsCurrentTime = [self.visibleDays containsDate:[NSDate date]];
	
    self.timeScrollView.userInteractionEnabled = NO;
    
    
    self.dayColumnsView.frame = CGRectMake(self.timeColumnWidth, 0, timedEventsViewWidth, self.bounds.size.height);
    if (!self.dayColumnsView.superview) {
        [self addSubview:self.dayColumnsView];
    }

    self.dayColumnsView.userInteractionEnabled = NO;

    // make sure collection views are synchronized
    self.dayColumnsView.contentOffset = CGPointMake(self.timedEventsView.contentOffset.x, 0);
    self.timeScrollView.contentOffset = CGPointMake(0, self.timedEventsView.contentOffset.y);

	if (self.dragTimer == nil && self.interactiveCell && self.interactiveCellDate) {
		CGRect frame = self.interactiveCell.frame;
        frame.origin = [self offsetFromDate:self.interactiveCellDate eventType:self.interactiveCellType];
        frame.size.width = self.dayColumnSize.width;
		self.interactiveCell.frame = frame;
        self.interactiveCell.hidden = (self.interactiveCellType == MGCTimedEventType && !CGRectIntersectsRect(self.timedEventsView.frame, frame));
	}
}

#pragma mark - UIView

- (void)layoutSubviews
{
	//NSLog(@"layout subviews");

    [super layoutSubviews];
    
    CGSize dayColumnSize = self.dayColumnSize;
    
    self.timeRowsView.hourSlotHeight = self.hourSlotHeight;
    self.timeRowsView.timeColumnWidth = self.timeColumnWidth;
    self.timeRowsView.insetsHeight = self.eventsViewInnerMargin;
    
    self.timedEventsViewLayout.dayColumnSize = dayColumnSize;
    self.timedEventsViewLayout.heightLoadMore = self.heightLoadMore;
    
	[self setupSubviews];
	[self updateVisibleDaysRange];
}

#pragma mark - ShiftTimeRowsViewDelegate
- (NSAttributedString*) timeRowsViewAttributedStringBagde:(ShiftTimeRowsView *)view withIndex:(NSInteger)index{
    if ([self.delegate respondsToSelector:@selector(dayPlannerViewAttribuedStringBagde:withIndex:)]) {
        return [self.delegate dayPlannerViewAttribuedStringBagde:self withIndex:index ];
    }
    return nil;
}

-(NSAttributedString*) timeRowsViewAttributedStringMark:(ShiftTimeRowsView *)view withIndex:(NSInteger)index{
    if ([self.delegate respondsToSelector:@selector(dayPlannerViewAttributedStringMark:withIndex:)]) {
        return [self.delegate dayPlannerViewAttributedStringMark:self withIndex:index];
    }
    return nil;
}

- (NSAttributedString*) timeRowsViewAttributedStringGuest:(ShiftTimeRowsView *)view withIndex:(NSInteger)index{
    if ([self.delegate respondsToSelector:@selector(dayPlannerViewttributedStringGuest:withIndex:)]) {
        return [self.delegate dayPlannerViewttributedStringGuest:self withIndex:index];
    }
    return nil;
}

#pragma mark - UICollectionViewDataSource

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView*)collectionView
{
	return self.numberOfLoadedDays;
}

// public
- (NSInteger)numberOfTimedEventsAtDate:(NSDate*)date
{
    NSInteger section = [self dayOffsetFromDate:date];
	return [self.timedEventsView numberOfItemsInSection:section];
}

// public
- (NSArray*)visibleEventViewsOfType:(MGCEventType)type
{
	NSMutableArray *views = [NSMutableArray array];
	if (type == MGCTimedEventType) {
		NSArray *visibleCells = [self.timedEventsView visibleCells];
		for (MGCEventCell *cell in visibleCells) {
			[views addObject:cell.eventView];
		}
	}
	return views;
}

- (MGCEventCell*)collectionViewCellForEventOfType:(MGCEventType)type atIndexPath:(NSIndexPath*)indexPath
{
	MGCEventCell *cell = nil;
	if (type == MGCTimedEventType) {
		cell = (MGCEventCell*)[self.timedEventsView cellForItemAtIndexPath:indexPath];
	}
	return cell;
}

- (NSInteger)collectionView:(UICollectionView*)collectionView numberOfItemsInSection:(NSInteger)section
{
	if (collectionView == self.timedEventsView) {
        return _sizeEventInSection;
	}
	return 1; // for dayColumnView
}



- (UICollectionViewCell*)dayColumnCellAtIndexPath:(NSIndexPath*)indexPath
{
    ShiftDayColumnCell *dayCell = [self.dayColumnsView dequeueReusableCellWithReuseIdentifier:DayColumnCellReuseIdentifier forIndexPath:indexPath];
    // set up arr
    dayCell.separatorColor = self.daySeparatorsColor;
    dayCell.heightHeaderDayCell = self.heightHeaderDayCell;
    dayCell.fontSizeNameDay = self.fontSizeNameHeaderDay;
    dayCell.maxCellVisible = self.maxCellVisible;
    dayCell.indexDate = [self.calendar mgc_startOfDayForDate:_indexDate];
    
    NSDate *date = [self.calendar mgc_startOfDayForDate:[self dateFromDayOffset:indexPath.section]];
    dayCell.currentDate = date;
    
    NSAttributedString *attrStr = nil;
    if ([self.delegate respondsToSelector:@selector(dayPlannerView:attributedStringForDayHeaderAtDate:)]) {
        attrStr = [self.delegate dayPlannerView:self attributedStringForDayHeaderAtDate:date];
    }

    if (attrStr) {
        UIFont *font = [UIFont systemFontOfSize:self.fontSizeNameHeaderDay];
        attrStr = [[NSMutableAttributedString alloc]initWithString:attrStr.string attributes:@{ NSFontAttributeName:font }];
    }
    
    dayCell.dayLabel.attributedText = attrStr;
    dayCell.listHeaderCell = self.listHeaderCell;
    dayCell.accessoryTypes = ShiftDayColumnCellAccessoryBorder;
    return dayCell;
}

- (UICollectionViewCell*)dequeueCellForEventOfType:(MGCEventType)type atIndexPath:(NSIndexPath*)indexPath
{
	NSDate *date = [self dateFromDayOffset:indexPath.section];
	NSUInteger index = indexPath.item;
	MGCEventView *cell = [self.dataSource dayPlannerView:self viewForEventOfType:type atIndex:index date:date];
	
	MGCEventCell *cvCell = nil;
	if (type == MGCTimedEventType) {
		cvCell = (MGCEventCell*)[self.timedEventsView dequeueReusableCellWithReuseIdentifier:EventCellReuseIdentifier forIndexPath:indexPath];
	}
	
	cvCell.eventView = cell;
	if ([self.selectedCellIndexPath isEqual:indexPath] && self.selectedCellType == type) {
		cvCell.selected = YES;
	}
		
	return cvCell;
}

- (UICollectionViewCell*)collectionView:(UICollectionView*)collectionView cellForItemAtIndexPath:(NSIndexPath*)indexPath
{
	if (collectionView == self.timedEventsView) {
		return [self dequeueCellForEventOfType:MGCTimedEventType atIndexPath:indexPath];
	}
	else if (collectionView == self.dayColumnsView) {
		return [self dayColumnCellAtIndexPath:indexPath];
	}
	return nil;
}

- (UICollectionReusableView*)collectionView:(UICollectionView*)collectionView viewForSupplementaryElementOfKind:(NSString*)kind atIndexPath:(NSIndexPath*)indexPath
{
    if ([kind isEqualToString:DimmingViewKind]) {
        UICollectionReusableView *view = [self.timedEventsView dequeueReusableSupplementaryViewOfKind:DimmingViewKind withReuseIdentifier:DimmingViewReuseIdentifier forIndexPath:indexPath];
        view.backgroundColor = self.dimmingColor;
        
        return view;
    }
    return nil;
}

#pragma mark - ShiftTimedEventsViewLayoutDelegate

- (CGRect)collectionView:(UICollectionView *)collectionView layout:(ShiftTimedEventsViewLayout *)layout rectForEventAtIndexPath:(NSIndexPath *)indexPath{
    CGFloat y1 = MGCAlignedFloat(indexPath.item*self.hourSlotHeight);
    CGFloat y2 = MGCAlignedFloat((indexPath.item + 1)*self.hourSlotHeight);
    return CGRectMake(0, y1, 0, y2 - y1);
}

- (NSArray*)dimmedTimeRangesAtDate:(NSDate*)date
{
    NSMutableArray *ranges = [NSMutableArray array];

    if ([self.delegate respondsToSelector:@selector(dayPlannerView:numberOfDimmedTimeRangesAtDate:)]) {
        NSInteger count = [self.delegate dayPlannerView:self numberOfDimmedTimeRangesAtDate:date];

        if (count > 0 && [self.delegate respondsToSelector:@selector(dayPlannerView:dimmedTimeRangeAtIndex:date:)]) {
//            MGCDateRange *dayRange = [self scrollableTimeRangeForDate:date];

            for (NSUInteger i = 0; i < count; i++) {
                MGCDateRange *range = [self.delegate dayPlannerView:self dimmedTimeRangeAtIndex:i date:date];

//                [range intersectDateRange:dayRange];

                if (!range.isEmpty) {
                    [ranges addObject:range];
                }
            }
        }
    }
    return ranges;
}

- (NSArray*)collectionView:(UICollectionView *)collectionView layout:(ShiftTimedEventsViewLayout *)layout dimmingRectsForSection:(NSUInteger)section
{
    NSDate *date = [self dateFromDayOffset:section];

    NSArray *ranges = [self.dimmedTimeRangesCache objectForKey:date];
    if (!ranges) {
        ranges = [self dimmedTimeRangesAtDate:date];
        [self.dimmedTimeRangesCache setObject:ranges forKey:date];
    }

    NSMutableArray *rects = [NSMutableArray arrayWithCapacity:ranges.count];

    for (MGCDateRange *range in ranges) {
        if (!range.isEmpty) {
            CGFloat y1 = [self offsetFromDate:range.start];
            CGFloat y2 = [self offsetFromDate:range.end];

            [rects addObject:[NSValue valueWithCGRect:CGRectMake(0, y1, 0, y2 - y1)]];
        }
    }
    return rects;
}


#pragma mark - UICollectionViewDelegate

//- (void)collectionView:(UICollectionView*)collectionView willDisplayCell:(UICollectionViewCell*)cell forItemAtIndexPath:(NSIndexPath*)indexPath
//{
//}
//
//- (void)collectionView:(UICollectionView*)collectionView didEndDisplayingCell:(UICollectionViewCell*)cell forItemAtIndexPath:(NSIndexPath*)indexPath
//{
//}

// this is only supported on iOS 9 and above
- (CGPoint)collectionView:(UICollectionView *)collectionView targetContentOffsetForProposedContentOffset:(CGPoint)proposedContentOffset
{
    if (self.scrollTargetDate) {
        NSInteger targetSection = [self dayOffsetFromDate:self.scrollTargetDate];
        proposedContentOffset.x  = targetSection * self.dayColumnSize.width;
    }
    return proposedContentOffset;
}

#pragma mark - Scrolling utilities

// The difficulty with scrolling is that:
// - we have to synchronize between the different collection views
// - we have to restrict dragging to one direction at a time
// - we have to recenter the views when needed to make the infinite scrolling possible
// - we have to deal with possibly nested scrolls (animating or tracking while decelerating...)


// this is a single entry point for scrolling, called by scrollViewWillBeginDragging: when dragging starts,
// and before any "programmatic" scrolling outside of an already started scroll operation, like scrollToDate:animated:
// If direction is ScrollDirectionUnknown, it will be determined on first scrollViewDidScroll: received
- (void)scrollViewWillStartScrolling:(UIScrollView*)scrollView direction:(ScrollDirection)direction
{
    NSAssert(scrollView == self.timedEventsView, @"For synchronizing purposes, only timedEventsView or allDayEventsView are allowed to scroll");
	
	if (self.controllingScrollView) {
		NSAssert(scrollView == self.controllingScrollView, @"Scrolling on two different views at the same time is not allowed");

		// we might be dragging while decelerating on the same view, but scrolling will be
		// locked according to the initial axis
	}
	
	//NSLog(@"scrollViewWillStartScrolling direction: %d", (int)direction);
	
	//[self deselectEventWithDelegate:YES];
	
	if (self.controllingScrollView == nil) {
		// we have to restrict dragging to one view at a time
		// until the whole scroll operation finishes.
		
		if (scrollView != self.timedEventsView) {
			self.timedEventsView.scrollEnabled = NO;
		}
		
		// note which view started scrolling - for synchronizing,
		// and the start offset in order to determine direction
		self.controllingScrollView = scrollView;
		self.scrollStartOffset = scrollView.contentOffset;
		self.scrollDirection = direction;
	}
}

// even though directionalLockEnabled is set on both scrolling-enabled scrollviews,
// one can still scroll diagonally if the scrollview is dragged in both directions at the same time.
// This is not what we want!
- (void)lockScrollingDirection
{
	NSAssert(self.controllingScrollView, @"Trying to lock scrolling direction while no scroll operation has started");
	
	CGPoint contentOffset = self.controllingScrollView.contentOffset;
	if (self.scrollDirection == ScrollDirectionUnknown) {
		// determine direction
		if (fabs(self.scrollStartOffset.x - contentOffset.x) < fabs(self.scrollStartOffset.y - contentOffset.y)) {
			self.scrollDirection = ScrollDirectionVertical;
		}
		else {
			self.scrollDirection = ScrollDirectionHorizontal;
		}
	}
	
	// lock scroll position of the scrollview according to detected direction
	if (self.scrollDirection & ScrollDirectionVertical) {
		[self.controllingScrollView	setContentOffset:CGPointMake(self.scrollStartOffset.x, contentOffset.y)];
	}
	else if (self.scrollDirection & ScrollDirectionHorizontal) {
		[self.controllingScrollView setContentOffset:CGPointMake(contentOffset.x, self.scrollStartOffset.y)];
	}
}

// calculates the new start date, given a date to be the first visible on the left.
// if offset is not nil, it contains on return the number of days between this new start date
// and the first visible date.
- (NSDate*)startDateForFirstVisibleDate:(NSDate*)date dayOffset:(NSUInteger*)offset
{
	NSAssert(date, @"startDateForFirstVisibleDate:dayOffset: was passed nil date");
	
	date = [self.calendar mgc_startOfDayForDate:date];
	
	NSDateComponents *comps = [NSDateComponents new];
	comps.day = -kDaysLoadingStep * self.numberOfVisibleDays;
	NSDate *start = [self.calendar dateByAddingComponents:comps toDate:date options:0];
	
	// stay within the limits of our date range
	if (self.dateRange && [start compare:self.dateRange.start] == NSOrderedAscending) {
		start = self.dateRange.start;
	}
	else if (self.maxStartDate && [start compare:self.maxStartDate] == NSOrderedDescending) {
		start = self.maxStartDate;
	}
	
	if (offset) {
		*offset = abs((int)[self.calendar components:NSCalendarUnitDay fromDate:start toDate:date options:0].day);
	}
	return start;
}

// if necessary, recenters horizontally the controlling scroll view to permit infinite scrolling.
// this is called by scrollViewDidScroll:
// returns YES if we loaded new pages, NO otherwise
- (BOOL)recenterIfNeeded
{
    
	NSAssert(self.controllingScrollView, @"Trying to recenter with no controlling scroll view");
	
	CGFloat xOffset = self.controllingScrollView.contentOffset.x;
	CGFloat xContentSize = self.controllingScrollView.contentSize.width;
	CGFloat xPageSize = self.controllingScrollView.bounds.size.width;
	
	// this could eventually be tweaked - for now we recenter when we have less than a page on one or the other side
	if (xOffset < xPageSize || xOffset + 2 * xPageSize > xContentSize) {
		NSDate *newStart = [self startDateForFirstVisibleDate:self.visibleDays.start dayOffset:nil];
		NSInteger diff = [self.calendar components:NSCalendarUnitDay fromDate:self.startDate toDate:newStart options:0].day;
		
		if (diff != 0) {
			self.startDate = newStart;
			[self reloadCollectionViews];
			
			CGFloat newXOffset = -diff * self.dayColumnSize.width + self.controllingScrollView.contentOffset.x;
			[self.controllingScrollView setContentOffset:CGPointMake(newXOffset, self.controllingScrollView.contentOffset.y)];
			return YES;
		}
	}
	return NO;
}

// this is called by scrollViewDidScroll: to synchronize the collections views
// vertically (timedEventsView with timeRowsView), and horizontally (allDayEventsView with timedEventsView and dayColumnsView)
- (void)synchronizeScrolling
{
	NSAssert(self.controllingScrollView, @"Synchronizing scrolling with no controlling scroll view");
	
	CGPoint contentOffset = self.controllingScrollView.contentOffset;
        if (self.controllingScrollView == self.timedEventsView) {
		
		if (self.scrollDirection & ScrollDirectionHorizontal) {
			self.dayColumnsView.contentOffset = CGPointMake(contentOffset.x, 0);
		}
		else {
			self.timeScrollView.contentOffset = CGPointMake(0, contentOffset.y);
		}
	}
}

// this is called at the end of every scrolling operation, initiated by user or programatically
- (void)scrollViewDidEndScrolling:(UIScrollView*)scrollView
{
	//NSLog(@"scrollViewDidEndScrolling");
	
	// reset everything
	if (scrollView == self.controllingScrollView) {
		ScrollDirection direction = self.scrollDirection;
		
		self.scrollDirection = ScrollDirectionUnknown;
		self.timedEventsView.scrollEnabled = YES;
		self.controllingScrollView = nil;
		
		if (self.scrollViewAnimationCompletionBlock) {
			dispatch_async(dispatch_get_main_queue(), self.scrollViewAnimationCompletionBlock);
			self.scrollViewAnimationCompletionBlock =  nil;
		}
		
        if (direction == ScrollDirectionHorizontal) {
            [self setupSubviews];  // allDayEventsView might need to be resized
        }
        
		if ([self.delegate respondsToSelector:@selector(dayPlannerView:didEndScrolling:)]) {
			MGCDayPlannerScrollType type = direction == ScrollDirectionHorizontal ? MGCDayPlannerScrollDate : MGCDayPlannerScrollTime;
			[self.delegate dayPlannerView:self didEndScrolling:type];
		}
	}
}

																					
// this is the entry point for every programmatic scrolling of the timed events view
- (void)setTimedEventsViewContentOffset:(CGPoint)offset animated:(BOOL)animated completion:(void (^)(void))completion
{
	// animated programmatic scrolling is prohibited while another scrolling operation is in progress
	if (self.controllingScrollView)  return;
    
	CGPoint prevOffset = self.timedEventsView.contentOffset;

    if (animated && !CGPointEqualToPoint(offset, prevOffset)) {
        [[UIDevice currentDevice]endGeneratingDeviceOrientationNotifications];
    }

	self.scrollViewAnimationCompletionBlock = completion;
		
	[self scrollViewWillStartScrolling:self.timedEventsView direction:ScrollDirectionUnknown];
	[self.timedEventsView setContentOffset:offset animated:animated];
	
	if (!animated || CGPointEqualToPoint(offset, prevOffset)) {
		[self scrollViewDidEndScrolling:self.timedEventsView];
	}
}

- (void)updateVisibleDaysRange
{
	MGCDateRange *oldRange = self.previousVisibleDays;
	MGCDateRange *newRange = self.visibleDays;
	
	if ([oldRange isEqual:newRange]) return;
	
	if ([oldRange intersectsDateRange:newRange]) {
		MGCDateRange *range = [oldRange copy];
		[range unionDateRange:newRange];
		
		[range enumerateDaysWithCalendar:self.calendar usingBlock:^(NSDate *date, BOOL *stop){
			if ([oldRange containsDate:date] && ![newRange containsDate:date] &&
				[self.delegate respondsToSelector:@selector(dayPlannerView:didEndDisplayingDate:)])
			{
				[self.delegate dayPlannerView:self didEndDisplayingDate:date];
			}
			else if ([newRange containsDate:date] && ![oldRange containsDate:date] &&
				[self.delegate respondsToSelector:@selector(dayPlannerView:willDisplayDate:)])
			{
				[self.delegate dayPlannerView:self willDisplayDate:date];
			}
		}];
	}
	else {
		[oldRange enumerateDaysWithCalendar:self.calendar usingBlock:^(NSDate *date, BOOL *stop){
			if ([self.delegate respondsToSelector:@selector(dayPlannerView:didEndDisplayingDate:)]) {
				[self.delegate dayPlannerView:self didEndDisplayingDate:date];
			}
		}];
		[newRange enumerateDaysWithCalendar:self.calendar usingBlock:^(NSDate *date, BOOL *stop){
			if ([self.delegate respondsToSelector:@selector(dayPlannerView:willDisplayDate:)]) {
				[self.delegate dayPlannerView:self willDisplayDate:date];
			}
		}];
	}
	
	self.previousVisibleDays = newRange;
}

#pragma mark - UIScrollViewDelegate

- (void)scrollViewWillBeginDragging:(UIScrollView*)scrollView
{
	//NSLog(@"scrollViewWillBeginDragging");
	
	// direction will be determined on first scrollViewDidScroll: received
	[self scrollViewWillStartScrolling:scrollView direction:ScrollDirectionUnknown];
}

- (void)scrollViewDidScroll:(UIScrollView*)scrollview
{
    // avoid looping
	if (scrollview != self.controllingScrollView)
		return;
    
	//NSLog(@"scrollViewDidScroll");
	
	[self lockScrollingDirection];
	
	if (self.scrollDirection & ScrollDirectionHorizontal) {
        
		[self recenterIfNeeded];
	}
	
	[self synchronizeScrolling];
	
	[self updateVisibleDaysRange];
	
	if ([self.delegate respondsToSelector:@selector(dayPlannerView:didScroll:)]) {
		MGCDayPlannerScrollType type = self.scrollDirection == ScrollDirectionHorizontal ? MGCDayPlannerScrollDate : MGCDayPlannerScrollTime;
      
		[self.delegate dayPlannerView:self didScroll:type];
       
	}
    
    if(self.scrollDirection & ScrollDirectionVertical){
        if (scrollview.contentOffset.y >= scrollview.contentSize.height - scrollview.frame.size.height - 200  && !_isLimitLoadMore && !_isLoadMore) {
            
            [self showLoadMore];
            // The user did scroll to the bottom of the scroll view
            [self.delegate dayPlannerViewLoadMore:self];
        }
    }
}


- (void) showHideHeaderCell{
    MGCDateRange *range = [self visibleDays];
    NSDate *start = [self.calendar mgc_startOfDayForDate:range.start];
    NSDate *end = [self.calendar mgc_startOfDayForDate:range.end];
    end = [end dateByAddingTimeInterval:-24*60*60];
    NSInteger maxHeaderCell = 0;
    while(true){
        NSLog(@"Date: %@",start);
        NSArray* arr = [self.listHeaderCell objectForKey:start];
        if(arr){
            if(arr.count > maxHeaderCell)
                maxHeaderCell = arr.count;
        }
        start = [self.calendar mgc_nextStartOfDayForDate:start];
        if([start isEqual:[self.calendar mgc_nextStartOfDayForDate:end]])
            break;
    }
    if(self.maxCellVisible != maxHeaderCell){
        [self setMaxCellVisible:maxHeaderCell];
    }
}

-(void) showLoadMore{
    _isLoadMore = YES;
      [self.ShiftLoadMoreView setHidden:false];
}

-(void) hideLoadMore{
    _isLoadMore = NO;
    [self.ShiftLoadMoreView setHidden:true];
}



- (void)scrollViewWillEndDragging:(UIScrollView*)scrollView withVelocity:(CGPoint)velocity targetContentOffset:(inout CGPoint*)targetContentOffset
{
    //NSLog(@"scrollViewWillEndDragging horzVelocity: %f", velocity.x);
    
    if (!(self.scrollDirection & ScrollDirectionHorizontal)) return;
    
    CGFloat xOffset = targetContentOffset->x;
    
    if (fabs(velocity.x) < .7 || !self.pagingEnabled) {
        // stick to nearest section
        NSInteger section = roundf(targetContentOffset->x / self.dayColumnSize.width);
        xOffset = section * self.dayColumnSize.width;
        self.scrollTargetDate = [self dateFromDayOffset:section];
    }
    else if (self.pagingEnabled) {
        NSDate *date;
        
        // scroll to next page
        if (velocity.x > 0) {
            date = [self nextDateForPagingAfterDate:self.visibleDays.start];
         }
        // scroll to previous page
        else {
            date = [self prevDateForPagingBeforeDate:self.firstVisibleDate];
        }
        NSInteger section = [self dayOffsetFromDate:date];
        xOffset = [self xOffsetFromDayOffset:section];
        self.scrollTargetDate = [self dateFromDayOffset:section];
    }
        
    xOffset = fminf(fmax(xOffset, 0), scrollView.contentSize.width - scrollView.bounds.size.width);
    targetContentOffset->x = xOffset;
}


- (void)scrollViewDidEndDragging:(UIScrollView*)scrollView willDecelerate:(BOOL)decelerate
{
	//NSLog(@"scrollViewDidEndDragging decelerate: %d", decelerate);
	
	// (decelerate = NO and scrollView.decelerating = YES) means that a second scroll operation
	// started on the same scrollview while decelerating.
	// in that (rare) case, don't end up the operation, which could mess things up.
	// ex: swipe vertically and soon after swipe forward
	
	if (!decelerate && !scrollView.decelerating) {
		[self scrollViewDidEndScrolling:scrollView];
	}

    if (decelerate) {
        [[UIDevice currentDevice]endGeneratingDeviceOrientationNotifications];
    }
}

- (void)scrollViewDidEndDecelerating:(UIScrollView*)scrollView
{
    NSLog(@"scrollViewDidEndDecelerating");
    
    if(self.scrollDirection & ScrollDirectionHorizontal){
        [self showHideHeaderCell];
    }

	[self scrollViewDidEndScrolling:scrollView];
    
    [[UIDevice currentDevice]beginGeneratingDeviceOrientationNotifications];
}

- (void)scrollViewDidEndScrollingAnimation:(UIScrollView*)scrollView
{
	//NSLog(@"scrollViewDidEndScrollingAnimation");

	[self scrollViewDidEndScrolling:scrollView];
    
    [[UIDevice currentDevice]beginGeneratingDeviceOrientationNotifications];
}



#pragma mark - UICollectionViewDelegateFlowLayout

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath
{
    CGSize dayColumnSize = self.dayColumnSize;
    return CGSizeMake(dayColumnSize.width, self.bounds.size.height);
}

@end
