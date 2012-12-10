//
//  NSObject+RACBindings.m
//  ReactiveCocoa
//
//  Created by Josh Abernathy on 4/4/12.
//  Copyright (c) 2012 GitHub, Inc. All rights reserved.
//

#import "NSObject+RACBindings.h"
#import "RACSignal.h"
#import "NSObject+RACKVOWrapper.h"
#import "RACSubject.h"
#import "RACDisposable.h"
#import "RACScheduler.h"
#import "RACSwizzling.h"
#import "NSObject+RACPropertySubscribing.h"

static void *RACBindingsAsReceiverKey = &RACBindingsAsReceiverKey;
static void *RACBindingsAsOtherObjectKey = &RACBindingsAsOtherObjectKey;

static NSString * const RACBindingExceptionName = @"RACBinding exception";
static NSString * const RACBindingExceptionBindingKey = @"RACBindingExceptionBindingKey";

@interface RACBinding : NSObject

+ (instancetype)bindingWithReceiver:(id)receiver receiverKeyPath:(NSString *)receiverKeyPath receiverTransformer:(id(^)(id))receiverTransformer receiverScheduler:(RACScheduler *)receiverScheduler otherObject:(id)otherObject otherKeyPath:(NSString *)otherKeyPath otherTransformer:(id(^)(id))otherTransformer otherScheduler:(RACScheduler *)otherScheduler;

- (void)dispose;
- (void)receiverWillChangeValue;
- (void)receiverDidChangeValue;
- (void)otherObjectWillChangeValue;
- (void)otherObjectDidChangeValue;

@end

@interface NSObject (RACBindings_Private)

@property (nonatomic, strong) NSMutableSet *RACBindingsAsReceiver;
@property (nonatomic, strong) NSMutableSet *RACBindingsAsOtherObject;
- (void)rac_addAsReceiverForBinding:(RACBinding *)binding;
- (void)rac_removeAsReceiverForBinding:(RACBinding *)binding;
- (void)rac_addAsOtherObjectForBinding:(RACBinding *)binding;
- (void)rac_removeAsOtherObjectForBinding:(RACBinding *)binding;
- (void)rac_customWillChangeValueForKey:(NSString *)key;
- (void)rac_customDidChangeValueForKey:(NSString *)key;

@end

static void prepareClassForBindingIfNeeded(__unsafe_unretained Class class) {
	static dispatch_once_t onceToken;
	static NSMutableSet *swizzledClasses = nil;
	dispatch_once(&onceToken, ^{
		swizzledClasses = [[NSMutableSet alloc] init];
	});
	NSString *className = NSStringFromClass(class);
	@synchronized(swizzledClasses) {
		if (![swizzledClasses containsObject:className]) {
			RACSwizzle(class, @selector(willChangeValueForKey:), @selector(rac_customWillChangeValueForKey:));
			RACSwizzle(class, @selector(didChangeValueForKey:), @selector(rac_customDidChangeValueForKey:));
			[swizzledClasses addObject:className];
		}
	}
}

@interface RACBinding ()

@property (nonatomic, readonly, weak) id receiver;
@property (nonatomic, readonly, copy) NSString *receiverKeyPath;
@property (nonatomic, readonly, copy) id (^receiverTransformer)(id);
@property (nonatomic, readonly, strong) RACScheduler *receiverScheduler;
@property (nonatomic, readonly, weak) id otherObject;
@property (nonatomic, readonly, copy) NSString *otherKeyPath;
@property (nonatomic, readonly, copy) id (^otherTransformer)(id);
@property (nonatomic, readonly, strong) RACScheduler *otherScheduler;
@property (nonatomic, strong) id receiverObserver;
@property (nonatomic) NSUInteger receiverStackDepth;
@property (nonatomic) BOOL ignoreNextReceiverUpdate;
@property (nonatomic) NSUInteger receiverVersion;
@property (nonatomic, strong) id otherObserver;
@property (nonatomic) NSUInteger otherStackDepth;
@property (nonatomic) BOOL ignoreNextOtherUpdate;
@property (nonatomic) NSUInteger otherVersion;
@property (nonatomic) BOOL disposed;

- (instancetype)initWithReceiver:(id)receiver receiverKeyPath:(NSString *)receiverKeyPath receiverTransformer:(id(^)(id))receiverTransformer receiverScheduler:(RACScheduler *)receiverScheduler otherObject:(id)otherObject otherKeyPath:(NSString *)otherKeyPath otherTransformer:(id(^)(id))otherTransformer otherScheduler:(RACScheduler *)otherScheduler;

@end

@implementation RACBinding {
	volatile NSUInteger _currentVersion;
}

- (instancetype)initWithReceiver:(id)receiver receiverKeyPath:(NSString *)receiverKeyPath receiverTransformer:(id (^)(id))receiverTransformer receiverScheduler:(RACScheduler *)receiverScheduler otherObject:(id)otherObject otherKeyPath:(NSString *)otherKeyPath otherTransformer:(id (^)(id))otherTransformer otherScheduler:(RACScheduler *)otherScheduler {
	self = [super init];
	if (self == nil) return nil;
	_receiver = receiver;
	_receiverKeyPath = [receiverKeyPath copy];
	_receiverTransformer = [receiverTransformer copy];
	_receiverScheduler = receiverScheduler ?: [RACScheduler immediateScheduler];
	_receiverVersion = NSUIntegerMax;
	_otherObject = otherObject;
	_otherKeyPath = [otherKeyPath copy];
	_otherTransformer = [otherTransformer copy];
	_otherScheduler = otherScheduler ?: [RACScheduler immediateScheduler];
	_otherVersion = NSUIntegerMax;
	
	_receiverObserver = [_receiver rac_addObserver:self forKeyPath:_receiverKeyPath options:NSKeyValueObservingOptionPrior queue:nil block:nil];
	_otherObserver = [_otherObject rac_addObserver:self forKeyPath:_otherKeyPath options:NSKeyValueObservingOptionPrior queue:nil block:nil];

	[_otherScheduler schedule:^{
		id value = [self.otherObject valueForKeyPath:self.otherKeyPath];
		if (self.otherTransformer) value = self.otherTransformer(value);
		[self.receiverScheduler schedule:^{
			@synchronized(self) {
				if (self.disposed) return;
				[self.receiver setValue:value forKeyPath:self.receiverKeyPath];
				[self.receiver rac_addAsReceiverForBinding:self];
			}
		}];
		@synchronized(self) {
			if (self.disposed) return;
			[self.otherObject rac_addAsOtherObjectForBinding:self];
		}
	}];

	return self;
}

+ (instancetype)bindingWithReceiver:(id)receiver receiverKeyPath:(NSString *)receiverKeyPath receiverTransformer:(id (^)(id))receiverTransformer receiverScheduler:(RACScheduler *)receiverScheduler otherObject:(id)otherObject otherKeyPath:(NSString *)otherKeyPath otherTransformer:(id (^)(id))otherTransformer otherScheduler:(RACScheduler *)otherScheduler {
	return [[self alloc] initWithReceiver:receiver receiverKeyPath:receiverKeyPath receiverTransformer:receiverTransformer receiverScheduler:receiverScheduler otherObject:otherObject otherKeyPath:otherKeyPath otherTransformer:otherTransformer otherScheduler:otherScheduler];
}

- (void)dispose {
	@synchronized(self) {
		if (self.disposed) return;
		[self.receiver rac_removeObserverWithIdentifier:self.receiverObserver];
		[self.otherObject rac_removeObserverWithIdentifier:self.otherObserver];
		[self.receiver rac_removeAsReceiverForBinding:self];
		[self.otherObject rac_removeAsOtherObjectForBinding:self];
	}
}

- (void)receiverWillChangeValue {
	++self.receiverStackDepth;
}

- (void)receiverDidChangeValue {
	--self.receiverStackDepth;
	if (self.receiverStackDepth == NSUIntegerMax) @throw [NSException exceptionWithName:RACBindingExceptionName reason:@"Receiver called -didChangeValueForKey: without corresponding -willChangeValueForKey:" userInfo:@{ RACBindingExceptionBindingKey : self }];
	if (self.receiverStackDepth != 0) return;
	if (self.ignoreNextReceiverUpdate) {
		self.ignoreNextReceiverUpdate = NO;
		return;
	}
	NSUInteger currentVersion = __sync_fetch_and_add(&_currentVersion, 1);
	self.receiverVersion = currentVersion;
	id value = [self.receiver valueForKeyPath:self.receiverKeyPath];
	if (self.receiverTransformer) value = self.receiverTransformer(value);
	[self.otherScheduler schedule:^{
		if (self.otherVersion - currentVersion < NSUIntegerMax / 2) return;
		self.ignoreNextOtherUpdate = YES;
		@synchronized(self) {
			if (self.disposed) return;
			self.otherVersion = currentVersion;
			[self.otherObject setValue:value forKeyPath:self.otherKeyPath];
		}
	}];
}

- (void)otherObjectWillChangeValue {
	++self.otherStackDepth;
}

- (void)otherObjectDidChangeValue {
	--self.otherStackDepth;
	if (self.otherStackDepth == NSUIntegerMax) @throw [NSException exceptionWithName:RACBindingExceptionName reason:@"Other object called -didChangeValueForKey: without corresponding -willChangeValueForKey:" userInfo:@{ RACBindingExceptionBindingKey : self }];
	if (self.otherStackDepth != 0) return;
	if (self.ignoreNextOtherUpdate) {
		self.ignoreNextOtherUpdate = NO;
		return;
	}
	NSUInteger currentVersion = __sync_fetch_and_add(&_currentVersion, 1);
	self.otherVersion = currentVersion;
	id value = [self.otherObject valueForKeyPath:self.otherKeyPath];
	if (self.otherTransformer) value = self.otherTransformer(value);
	[self.receiverScheduler schedule:^{
		if (self.receiverVersion - currentVersion < NSUIntegerMax / 2) return;
		self.ignoreNextReceiverUpdate = YES;
		@synchronized(self) {
			if (self.disposed) return;
			self.receiverVersion = currentVersion;
			[self.receiver setValue:value forKeyPath:self.receiverKeyPath];
		}
	}];
}

@end

@implementation NSObject (RACBindings_Private)

- (NSMutableSet *)RACBindingsAsReceiver {
	return objc_getAssociatedObject(self, RACBindingsAsReceiverKey);
}

- (void)setRACBindingsAsReceiver:(NSMutableSet *)RACBindingsAsReceiver {
	objc_setAssociatedObject(self, RACBindingsAsReceiverKey, RACBindingsAsReceiver, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSMutableSet *)RACBindingsAsOtherObject {
	return objc_getAssociatedObject(self, RACBindingsAsOtherObjectKey);
}

- (void)setRACBindingsAsOtherObject:(NSMutableSet *)RACBindingsAsOtherObject {
	objc_setAssociatedObject(self, RACBindingsAsOtherObjectKey, RACBindingsAsOtherObject, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)rac_addAsReceiverForBinding:(RACBinding *)binding {
	prepareClassForBindingIfNeeded([self class]);
	@synchronized(self) {
		if (!self.RACBindingsAsReceiver) self.RACBindingsAsReceiver = [NSMutableSet set];
		[self.RACBindingsAsReceiver addObject:binding];
	}
}

- (void)rac_removeAsReceiverForBinding:(RACBinding *)binding {
	@synchronized(self) {
		[self.RACBindingsAsReceiver removeObject:binding];
	}
}

- (void)rac_addAsOtherObjectForBinding:(RACBinding *)binding {
	prepareClassForBindingIfNeeded([self class]);
	@synchronized(self) {
		if (!self.RACBindingsAsOtherObject) self.RACBindingsAsOtherObject = [NSMutableSet set];
		[self.RACBindingsAsOtherObject addObject:binding];
	}
}

- (void)rac_removeAsOtherObjectForBinding:(RACBinding *)binding {
	@synchronized(self) {
		[self.RACBindingsAsOtherObject removeObject:binding];
	}
}

- (void)rac_customWillChangeValueForKey:(NSString *)key {
	NSSet *bindingsAsReceiver = nil;
	NSSet *bindingsAsOtherObject = nil;
	@synchronized(self) {
		bindingsAsReceiver = [self.RACBindingsAsReceiver copy];
		bindingsAsOtherObject = [self.RACBindingsAsOtherObject copy];
	}
	for (RACBinding *binding in bindingsAsReceiver) {
    if (binding.receiver == self && [binding.receiverKeyPath isEqualToString:key]) {
			[binding receiverWillChangeValue];
		}
	}
	for (RACBinding *binding in bindingsAsOtherObject) {
    if (binding.otherObject == self && [binding.otherKeyPath isEqualToString:key]) {
			[binding otherObjectWillChangeValue];
		}
	}
	[self rac_customWillChangeValueForKey:key];
}

- (void)rac_customDidChangeValueForKey:(NSString *)key {
	NSSet *bindingsAsReceiver = nil;
	NSSet *bindingsAsOtherObject = nil;
	@synchronized(self) {
		bindingsAsReceiver = [self.RACBindingsAsReceiver copy];
		bindingsAsOtherObject = [self.RACBindingsAsOtherObject copy];
	}
	for (RACBinding *binding in bindingsAsReceiver) {
    if (binding.receiver == self && [binding.receiverKeyPath isEqualToString:key]) {
			[binding receiverDidChangeValue];
		}
	}
	for (RACBinding *binding in bindingsAsOtherObject) {
    if (binding.otherObject == self && [binding.otherKeyPath isEqualToString:key]) {
			[binding otherObjectDidChangeValue];
		}
	}
	[self rac_customDidChangeValueForKey:key];
}

@end

@implementation NSObject (RACBindings)

- (RACDisposable *)rac_bind:(NSString *)receiverKeyPath transformer:(id (^)(id))receiverTransformer onScheduler:(RACScheduler *)receiverScheduler toObject:(id)otherObject withKeyPath:(NSString *)otherKeyPath transformer:(id (^)(id))otherTransformer onScheduler:(RACScheduler *)otherScheduler {
	RACBinding *binding = [RACBinding bindingWithReceiver:self receiverKeyPath:receiverKeyPath receiverTransformer:receiverTransformer receiverScheduler:receiverScheduler otherObject:otherObject otherKeyPath:otherKeyPath otherTransformer:otherTransformer otherScheduler:otherScheduler];
	RACDisposable *disposable = [RACDisposable disposableWithBlock:^{
			[binding dispose];
	}];
	[self rac_addDeallocDisposable:disposable];
	[otherObject rac_addDeallocDisposable:disposable];
	return disposable;
}

@end
