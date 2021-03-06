//  JPEngine.m
//  JSPatch
//
//  Created by bang on 15/4/30.
//  Copyright (c) 2015 bang. All rights reserved.
//

#import "JPEngine.h"
#import <objc/runtime.h>
#import <objc/message.h>

#if TARGET_OS_IPHONE
#import <UIKit/UIApplication.h>
#endif

#if CGFLOAT_IS_DOUBLE
#define CGFloatValue doubleValue
#else
#define CGFloatValue floatValue
#endif

@implementation JPBoxing

#define JPBOXING_GEN(_name, _prop, _type) \
+ (instancetype)_name:(_type)obj  \
{   \
    JPBoxing *boxing = [[JPBoxing alloc] init]; \
    boxing._prop = obj;   \
    return boxing;  \
}

JPBOXING_GEN(boxObj, obj, id)
JPBOXING_GEN(boxPointer, pointer, void *)
JPBOXING_GEN(boxClass, cls, Class)
JPBOXING_GEN(boxWeakObj, weakObj, id)
JPBOXING_GEN(boxAssignObj, assignObj, id)

- (id)unbox
{
    if (self.obj) return self.obj;
    if (self.weakObj) return self.weakObj;
    if (self.assignObj) return self.assignObj;
    if (self.cls) return self.cls;
    return self;
}
- (void *)unboxPointer
{
    return self.pointer;
}
- (Class)unboxClass
{
    return self.cls;
}
@end

#pragma mark - Fix iOS7 NSInvocation fatal error
// A fatal error of NSInvocation on iOS7.0.
// A invocation return 0 when the return type is double/float.
// http://stackoverflow.com/questions/19874502/nsinvocation-getreturnvalue-with-double-value-produces-0-unexpectedly

typedef struct {double d;} JPDouble;
typedef struct {float f;} JPFloat;

static NSMethodSignature *fixSignature(NSMethodSignature *signature)
{
#if TARGET_OS_IPHONE
#ifdef __LP64__
    if (!signature) {
        return nil;
    }
    
    if ([[UIDevice currentDevice].systemVersion floatValue] < 7.09) {
        BOOL isReturnDouble = (strcmp([signature methodReturnType], "d") == 0);
        BOOL isReturnFloat = (strcmp([signature methodReturnType], "f") == 0);

        if (isReturnDouble || isReturnFloat) {
            NSMutableString *types = [NSMutableString stringWithFormat:@"%s@:", isReturnDouble ? @encode(JPDouble) : @encode(JPFloat)];
            for (int i = 2; i < signature.numberOfArguments; i++) {
                const char *argType = [signature getArgumentTypeAtIndex:i];
                [types appendFormat:@"%s", argType];
            }
            signature = [NSMethodSignature signatureWithObjCTypes:[types UTF8String]];
        }
    }
#endif
#endif
    return signature;
}

@interface NSObject (JPFix)
- (NSMethodSignature *)jp_methodSignatureForSelector:(SEL)aSelector;
+ (void)jp_fixMethodSignature;
@end

@implementation NSObject (JPFix)
const static void *JPFixedFlagKey = &JPFixedFlagKey;
- (NSMethodSignature *)jp_methodSignatureForSelector:(SEL)aSelector
{
    NSMethodSignature *signature = [self jp_methodSignatureForSelector:aSelector];
    return fixSignature(signature);
}

// 修复方法签名
+ (void)jp_fixMethodSignature
{
#if TARGET_OS_IPHONE
#ifdef __LP64__
    if ([[UIDevice currentDevice].systemVersion floatValue] < 7.1) {
        NSNumber *flag = objc_getAssociatedObject(self, JPFixedFlagKey);
        if (!flag.boolValue) {
            SEL originalSelector = @selector(methodSignatureForSelector:);
            SEL swizzledSelector = @selector(jp_methodSignatureForSelector:);
            Method originalMethod = class_getInstanceMethod(self, originalSelector);
            Method swizzledMethod = class_getInstanceMethod(self, swizzledSelector);
            BOOL didAddMethod = class_addMethod(self, originalSelector, method_getImplementation(swizzledMethod), method_getTypeEncoding(swizzledMethod));
            if (didAddMethod) {
                class_replaceMethod(self, swizzledSelector, method_getImplementation(originalMethod), method_getTypeEncoding(originalMethod));
            } else {
                method_exchangeImplementations(originalMethod, swizzledMethod);
            }
            objc_setAssociatedObject(self, JPFixedFlagKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
#endif
#endif
}
@end

#pragma mark -

static JSContext *_context;
static NSString *_regexStr = @"(?<!\\\\)\\.\\s*(\\w+)\\s*\\(";
static NSString *_replaceStr = @".__c(\"$1\")(";
static NSRegularExpression* _regex;
static NSObject *_nullObj;
static NSObject *_nilObj;
static NSMutableDictionary *_registeredStruct;
static NSMutableDictionary *_currInvokeSuperClsName;
static char *kPropAssociatedObjectKey;
static BOOL _autoConvert;
static BOOL _convertOCNumberToString;
static NSString *_scriptRootDir;
static NSMutableSet *_runnedScript;

static NSMutableDictionary *_JSOverideMethods;
static NSMutableDictionary *_TMPMemoryPool;
static NSMutableDictionary *_propKeys;
static NSMutableDictionary *_JSMethodSignatureCache;
static NSLock              *_JSMethodSignatureLock;
static NSRecursiveLock     *_JSMethodForwardCallLock;
static NSMutableDictionary *_protocolTypeEncodeDict;
static NSMutableArray      *_pointersToRelease;

#ifdef DEBUG
static NSArray *_JSLastCallStack;
#endif

// 打印异常信息
static void (^_exceptionBlock)(NSString *log) = ^void(NSString *log) {
    NSCAssert(NO, log);
};

@implementation JPEngine

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"

#pragma mark - APIS

// 开始JSPatch
+ (void)startEngine
{
    // 如果没有JSContext类对象或已经存在_context，则返回
    if (![JSContext class] || _context) {
        return;
    }
    
    // 创建 JSContext 实例，类似于Js中的window
    JSContext *context = [[JSContext alloc] init];
    
    // 通过block形式，注册js需要调用的方法
#ifdef DEBUG
    // 将 lldb 中 po 打印出来的字符串传递给 js
    context[@"po"] = ^JSValue*(JSValue *obj) {
        id ocObject = formatJSToOC(obj);
        return [JSValue valueWithObject:[ocObject description] inContext:_context];
    };

    // js 中打印调用堆栈，类似于 lldb 中的 bt
    context[@"bt"] = ^JSValue*() {
        return [JSValue valueWithObject:_JSLastCallStack inContext:_context];
    };
#endif

    // 在 OC 中定义 Class， 输入类的描述，实例方法数组 和 类方法数组
    context[@"_OC_defineClass"] = ^(NSString *classDeclaration, JSValue *instanceMethods, JSValue *classMethods) {
        return defineClass(classDeclaration, instanceMethods, classMethods);
    };

    // 在 OC 中定义协议，输入协议名
    context[@"_OC_defineProtocol"] = ^(NSString *protocolDeclaration, JSValue *instProtocol, JSValue *clsProtocol) {
        return defineProtocol(protocolDeclaration, instProtocol, clsProtocol);
    };
    
    // 调用 oc 的实例方法
    context[@"_OC_callI"] = ^id(JSValue *obj, NSString *selectorName, JSValue *arguments, BOOL isSuper) {
        return callSelector(nil, selectorName, arguments, obj, isSuper);
    };
    // 调用 oc 的类方法
    context[@"_OC_callC"] = ^id(NSString *className, NSString *selectorName, JSValue *arguments) {
        return callSelector(className, selectorName, arguments, nil, NO);
    };
    // 将 JS 对象转为 OC 对象
    context[@"_OC_formatJSToOC"] = ^id(JSValue *obj) {
        return formatJSToOC(obj);
    };
    
    // 将 OC 对象转为 JS对象
    context[@"_OC_formatOCToJS"] = ^id(JSValue *obj) {
        return formatOCToJS([obj toObject]);
    };
    
    // 获取 js 定义 class 的时候添加的自定义的 props
    context[@"_OC_getCustomProps"] = ^id(JSValue *obj) {
        id realObj = formatJSToOC(obj);
        return objc_getAssociatedObject(realObj, kPropAssociatedObjectKey);
    };
    
    // 设置 js 定义 class 时候自定义的 props
    context[@"_OC_setCustomProps"] = ^(JSValue *obj, JSValue *val) {
        id realObj = formatJSToOC(obj);
        objc_setAssociatedObject(realObj, kPropAssociatedObjectKey, val, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    };
    
    // js 对象弱引用, 主要用于 js 对象会传递给 OC 的情况
    context[@"__weak"] = ^id(JSValue *jsval) {
        id obj = formatJSToOC(jsval);
        return [[JSContext currentContext][@"_formatOCToJS"] callWithArguments:@[formatOCToJS([JPBoxing boxWeakObj:obj])]];
    };

    // js 对象强引用，将 js 弱引用r对象转为强引用
    context[@"__strong"] = ^id(JSValue *jsval) {
        id obj = formatJSToOC(jsval);
        return [[JSContext currentContext][@"_formatOCToJS"] callWithArguments:@[formatOCToJS(obj)]];
    };
    
    // 获取传入类的父类名
    context[@"_OC_superClsName"] = ^(NSString *clsName) {
        Class cls = NSClassFromString(clsName);
        return NSStringFromClass([cls superclass]);
    };
    
    // 设置标识位，在 formatOCToJS 的时候是否自动将 NSString  NSArray 等对象自动转为 js 中的 string，array 等。
    // 如果设置为 false，则会当成一个对象，使用 JPBoxing 包裹
    context[@"autoConvertOCType"] = ^(BOOL autoConvert) {
        _autoConvert = autoConvert;
    };

    // 设置标识位，在 formatOCToJS 的时候是否直接将 OC 的 NSNumber 类型转为 js 的 string 类型
    context[@"convertOCNumberToString"] = ^(BOOL convertOCNumberToString) {
        _convertOCNumberToString = convertOCNumberToString;
    };
    
    // 在 js 中调用 include 方法，可以在一个 js 文件中加载其他 js 文件
    context[@"include"] = ^(NSString *filePath) {
        NSString *absolutePath = [_scriptRootDir stringByAppendingPathComponent:filePath];
        if (!_runnedScript) {
            _runnedScript = [[NSMutableSet alloc] init];
        }
        if (absolutePath && ![_runnedScript containsObject:absolutePath]) {
            [JPEngine _evaluateScriptWithPath:absolutePath];
            [_runnedScript addObject:absolutePath];
        }
    };
    
    // 提供一个文件名返回完整的文件路径
    context[@"resourcePath"] = ^(NSString *filePath) {
        return [_scriptRootDir stringByAppendingPathComponent:filePath];
    };

    // 在主线程中延时执行
    context[@"dispatch_after"] = ^(double time, JSValue *func) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(time * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            // 执行 js 中 func  函数
            [func callWithArguments:nil];
        });
    };
    
    // 在主线程中异步执行
    context[@"dispatch_async_main"] = ^(JSValue *func) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // 执行 js 中 func  函数
            [func callWithArguments:nil];
        });
    };
    
    // 在主线程中同步执行
    context[@"dispatch_sync_main"] = ^(JSValue *func) {
        if ([NSThread currentThread].isMainThread) {
            // 执行 js 中 func  函数
            [func callWithArguments:nil];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                // 执行 js 中 func  函数
                [func callWithArguments:nil];
            });
        }
    };
    
    // 异步执行
    context[@"dispatch_async_global_queue"] = ^(JSValue *func) {
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            // 执行 js 中 func  函数
            [func callWithArguments:nil];
        });
    };
    
    // 释放二级指针指向的对象
    context[@"releaseTmpObj"] = ^void(JSValue *jsVal) {
        if ([[jsVal toObject] isKindOfClass:[NSDictionary class]]) {
            void *pointer =  [(JPBoxing *)([jsVal toObject][@"__obj"]) unboxPointer];
            id obj = *((__unsafe_unretained id *)pointer);
            @synchronized(_TMPMemoryPool) {
                [_TMPMemoryPool removeObjectForKey:[NSNumber numberWithInteger:[(NSObject*)obj hash]]];
            }
        }
    };
    
    // js 调用 oc 方法，打印 js 对象到 oc 控制台
    context[@"_OC_log"] = ^() {
        NSArray *args = [JSContext currentArguments];
        for (JSValue *jsVal in args) {
            id obj = formatJSToOC(jsVal);
            NSLog(@"JSPatch.log: %@", obj == _nilObj ? nil : (obj == _nullObj ? [NSNull null]: obj));
        }
    };
    
    // js 捕捉到的 exception 打印在 oc 中
    context[@"_OC_catch"] = ^(JSValue *msg, JSValue *stack) {
        _exceptionBlock([NSString stringWithFormat:@"js exception, \nmsg: %@, \nstack: \n %@", [msg toObject], [stack toObject]]);
    };
    
    context.exceptionHandler = ^(JSContext *con, JSValue *exception) {
        NSLog(@"%@", exception);
        _exceptionBlock([NSString stringWithFormat:@"js exception: %@", exception]);
    };
    
    // js 中的 nsnull 就是 oc 中的一个普通对象
    _nullObj = [[NSObject alloc] init];
    context[@"_OC_null"] = formatOCToJS(_nullObj);
    
    _context = context;
    
    // 各种初始化
    _nilObj = [[NSObject alloc] init];
    _JSMethodSignatureLock = [[NSLock alloc] init];
    _JSMethodForwardCallLock = [[NSRecursiveLock alloc] init];
    _registeredStruct = [[NSMutableDictionary alloc] init];
    _currInvokeSuperClsName = [[NSMutableDictionary alloc] init];
    
#if TARGET_OS_IPHONE
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleMemoryWarning) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
#endif
    
    // 获取 JSPatch.js 的路径
    NSString *path = [[NSBundle bundleForClass:[self class]] pathForResource:@"JSPatch" ofType:@"js"];
    if (!path) _exceptionBlock(@"can't find JSPatch.js");
    // 获取 SPatch.js 内容
    NSString *jsCore = [[NSString alloc] initWithData:[[NSFileManager defaultManager] contentsAtPath:path] encoding:NSUTF8StringEncoding];
    
    // 执行 JSPatch.js
    if ([_context respondsToSelector:@selector(evaluateScript:withSourceURL:)]) {
        [_context evaluateScript:jsCore withSourceURL:[NSURL URLWithString:@"JSPatch.js"]];
    } else {
        [_context evaluateScript:jsCore];
    }
}

// 执行脚本
+ (JSValue *)evaluateScript:(NSString *)script
{
    return [self _evaluateScript:script withSourceURL:[NSURL URLWithString:@"main.js"]];
}

+ (JSValue *)evaluateScriptWithPath:(NSString *)filePath
{
    _scriptRootDir = [filePath stringByDeletingLastPathComponent];
    return [self _evaluateScriptWithPath:filePath];
}

+ (JSValue *)_evaluateScriptWithPath:(NSString *)filePath
{
    NSString *script = [NSString stringWithContentsOfFile:filePath encoding:NSUTF8StringEncoding error:nil];
    return [self _evaluateScript:script withSourceURL:[NSURL URLWithString:[filePath lastPathComponent]]];
}

+ (JSValue *)_evaluateScript:(NSString *)script withSourceURL:(NSURL *)resourceURL
{
    if (!script || ![JSContext class]) {
        _exceptionBlock(@"script is nil");
        return nil;
    }
    // 查看_context是否已经创建，无，则创建、进行初始化工作
    [self startEngine];
    
    if (!_regex) {
        // 生成正则表达式对象
        _regex = [NSRegularExpression regularExpressionWithPattern:_regexStr options:0 error:nil];
    }
    // 使用正则表达式替换方法调用方式，将 alloc() 这样的函数调用，替换为 __c("alloc")() 形式，再拼接字符串
    NSString *formatedScript = [NSString stringWithFormat:@";(function(){try{\n%@\n}catch(e){_OC_catch(e.message, e.stack)}})();", [_regex stringByReplacingMatchesInString:script options:0 range:NSMakeRange(0, script.length) withTemplate:_replaceStr]];
    // 执行需要处理的修复方法
    @try {
        if ([_context respondsToSelector:@selector(evaluateScript:withSourceURL:)]) {
            return [_context evaluateScript:formatedScript withSourceURL:resourceURL];
        } else {
            return [_context evaluateScript:formatedScript];
        }
    }
    @catch (NSException *exception) {
        _exceptionBlock([NSString stringWithFormat:@"%@", exception]);
    }
    return nil;
}

+ (JSContext *)context
{
    return _context;
}

+ (void)addExtensions:(NSArray *)extensions
{
    if (![JSContext class]) {
        return;
    }
    if (!_context) _exceptionBlock(@"please call [JPEngine startEngine]");
    for (NSString *className in extensions) {
        Class extCls = NSClassFromString(className);
        [extCls main:_context];
    }
}

+ (void)defineStruct:(NSDictionary *)defineDict
{
    @synchronized (_context) {
        [_registeredStruct setObject:defineDict forKey:defineDict[@"name"]];
    }
}

+ (void)handleMemoryWarning {
    [_JSMethodSignatureLock lock];
    _JSMethodSignatureCache = nil;
    [_JSMethodSignatureLock unlock];
}

+ (void)handleException:(void (^)(NSString *msg))exceptionBlock
{
    _exceptionBlock = [exceptionBlock copy];
}

#pragma mark - Implements

static const void *propKey(NSString *propName) {
    if (!_propKeys) _propKeys = [[NSMutableDictionary alloc] init];
    id key = _propKeys[propName];
    if (!key) {
        key = [propName copy];
        [_propKeys setObject:key forKey:propName];
    }
    return (__bridge const void *)(key);
}
static id getPropIMP(id slf, SEL selector, NSString *propName) {
    return objc_getAssociatedObject(slf, propKey(propName));
}
static void setPropIMP(id slf, SEL selector, id val, NSString *propName) {
    objc_setAssociatedObject(slf, propKey(propName), val, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// 获取 protocol 中相应方法的函数签名
static char *methodTypesInProtocol(NSString *protocolName, NSString *selectorName, BOOL isInstanceMethod, BOOL isRequired)
{
    // 获取 protocol
    Protocol *protocol = objc_getProtocol([trim(protocolName) cStringUsingEncoding:NSUTF8StringEncoding]);
    unsigned int selCount = 0;
    // 复制 protocol 的方法列表
    struct objc_method_description *methods = protocol_copyMethodDescriptionList(protocol, isRequired, isInstanceMethod, &selCount);
    // 遍历 protocol 的方法列表，找到和目标方法同名的方法，然后通过 c 方法复制出来返回。否则返回 NULL
    for (int i = 0; i < selCount; i ++) {
        if ([selectorName isEqualToString:NSStringFromSelector(methods[i].name)]) {
            // strlen：获取字符长度，参数只能是char* 且必须是以'\0'结尾的
            // malloc：分配内存
            char *types = malloc(strlen(methods[i].types) + 1);
            // 将methods[i].types 拷贝到 types
            strcpy(types, methods[i].types);
            free(methods);
            return types;
        }
    }
    free(methods);
    return NULL;
}

// 动态创建一个 protocol
// instProtocol 与 clsProtocol js传过来的是一个字典，键是方法名，值是参数、返回值、方法的typeEncode：
 /*
 {
    someFunctionName: {
      paramsType: "param1,param2,param3",
      returnType: "returnType",
      typeEncode: "v@:"
    }
  }
 */
static void defineProtocol(NSString *protocolDeclaration, JSValue *instProtocol, JSValue *clsProtocol)
{
    const char *protocolName = [protocolDeclaration UTF8String];
    // runtime 动态创建一个 protocol
    Protocol* newprotocol = objc_allocateProtocol(protocolName);
    if (newprotocol) {
        // 为创建出来的 protocol 添加方法
        addGroupMethodsToProtocol(newprotocol, instProtocol, YES);
        addGroupMethodsToProtocol(newprotocol, clsProtocol, NO);
        // 注册协议
        objc_registerProtocol(newprotocol);
    }
}

// 为 protocol 添加方法
static void addGroupMethodsToProtocol(Protocol* protocol,JSValue *groupMethods,BOOL isInstance)
{
    NSDictionary *groupDic = [groupMethods toDictionary];
    for (NSString *jpSelector in groupDic.allKeys) {
        // 获取代表每一个方法的字典
        NSDictionary *methodDict = groupDic[jpSelector];
        // 从字典中取出参数列表
        NSString *paraString = methodDict[@"paramsType"];
        // 取出返回类型，如果没有就是 void
        NSString *returnString = methodDict[@"returnType"] && [methodDict[@"returnType"] length] > 0 ? methodDict[@"returnType"] : @"void";
        // 取出方法的typeEncode
        NSString *typeEncode = methodDict[@"typeEncode"];
        
        // 由于参数列表以 ，分割的字符串的形式传递，所以切割参数列表
        NSArray *argStrArr = [paraString componentsSeparatedByString:@","];
        // 获取真正的方法名
        NSString *selectorName = convertJPSelectorString(jpSelector);
        
        // 为了js端的写法好看点，末尾的参数可以不用写 `_`
        // 完善方法名称，末尾添加 : 符号
        if ([selectorName componentsSeparatedByString:@":"].count - 1 < argStrArr.count) {
            selectorName = [selectorName stringByAppendingString:@":"];
        }

        // 如果有 typeEnable，那么直接添加方法
        if (typeEncode) {
            addMethodToProtocol(protocol, selectorName, typeEncode, isInstance);
            
        } else {
            if (!_protocolTypeEncodeDict) {
                _protocolTypeEncodeDict = [[NSMutableDictionary alloc] init];
                // 利用 # 宏，来将  _type 字符串化，键是 type，值是 type 的 encode
                #define JP_DEFINE_TYPE_ENCODE_CASE(_type) \
                    [_protocolTypeEncodeDict setObject:[NSString stringWithUTF8String:@encode(_type)] forKey:@#_type];\

                JP_DEFINE_TYPE_ENCODE_CASE(id);
                JP_DEFINE_TYPE_ENCODE_CASE(BOOL);
                JP_DEFINE_TYPE_ENCODE_CASE(int);
                JP_DEFINE_TYPE_ENCODE_CASE(void);
                JP_DEFINE_TYPE_ENCODE_CASE(char);
                JP_DEFINE_TYPE_ENCODE_CASE(short);
                JP_DEFINE_TYPE_ENCODE_CASE(unsigned short);
                JP_DEFINE_TYPE_ENCODE_CASE(unsigned int);
                JP_DEFINE_TYPE_ENCODE_CASE(long);
                JP_DEFINE_TYPE_ENCODE_CASE(unsigned long);
                JP_DEFINE_TYPE_ENCODE_CASE(long long);
                JP_DEFINE_TYPE_ENCODE_CASE(float);
                JP_DEFINE_TYPE_ENCODE_CASE(double);
                JP_DEFINE_TYPE_ENCODE_CASE(CGFloat);
                JP_DEFINE_TYPE_ENCODE_CASE(CGSize);
                JP_DEFINE_TYPE_ENCODE_CASE(CGRect);
                JP_DEFINE_TYPE_ENCODE_CASE(CGPoint);
                JP_DEFINE_TYPE_ENCODE_CASE(CGVector);
                JP_DEFINE_TYPE_ENCODE_CASE(NSRange);
                JP_DEFINE_TYPE_ENCODE_CASE(NSInteger);
                JP_DEFINE_TYPE_ENCODE_CASE(Class);
                JP_DEFINE_TYPE_ENCODE_CASE(SEL);
                JP_DEFINE_TYPE_ENCODE_CASE(void*);
#if TARGET_OS_IPHONE
                JP_DEFINE_TYPE_ENCODE_CASE(UIEdgeInsets);
#else
                JP_DEFINE_TYPE_ENCODE_CASE(NSEdgeInsets);
#endif

                [_protocolTypeEncodeDict setObject:@"@?" forKey:@"block"];
                [_protocolTypeEncodeDict setObject:@"^@" forKey:@"id*"];
            }
            
            // 设置返回值的 encode
            NSString *returnEncode = _protocolTypeEncodeDict[returnString];
            // 拼接上所有的 encode 成为这个方法的 encode
            if (returnEncode.length > 0) {
                NSMutableString *encode = [returnEncode mutableCopy];
                [encode appendString:@"@:"];
                for (NSInteger i = 0; i < argStrArr.count; i++) {
                    // 参数名称
                    NSString *argStr = trim([argStrArr objectAtIndex:i]);
                    // 对应 encode
                    NSString *argEncode = _protocolTypeEncodeDict[argStr];
                    if (!argEncode) {
                        NSString *argClassName = trim([argStr stringByReplacingOccurrencesOfString:@"*" withString:@""]);
                        if (NSClassFromString(argClassName) != NULL) {
                            argEncode = @"@";
                        } else {
                            _exceptionBlock([NSString stringWithFormat:@"unreconized type %@", argStr]);
                            return;
                        }
                    }
                    [encode appendString:argEncode];
                }
                // 拼接好方法签名后给 protocol 增加方法
                addMethodToProtocol(protocol, selectorName, encode, isInstance);
            }
        }
    }
}

// 真正的添加 protocol 方法的地方
static void addMethodToProtocol(Protocol* protocol, NSString *selectorName, NSString *typeencoding, BOOL isInstance)
{
    SEL sel = NSSelectorFromString(selectorName);
    const char* type = [typeencoding UTF8String];
    protocol_addMethodDescription(protocol, sel, type, YES, isInstance);
}

// classDeclaration：类名，父类，协议的描述，cls:supercls<protoclo..>
// instMethods：实例方法列表
// clsMethods：类方法列表
static NSDictionary *defineClass(NSString *classDeclaration, JSValue *instanceMethods, JSValue *classMethods)
{
    // 扫描字符串做匹配
    NSScanner *scanner = [NSScanner scannerWithString:classDeclaration];
    NSString *className;
    NSString *superClassName;
    NSString *protocolNames;
    // 扫描到 ：了，把之前的放到 className 中
    [scanner scanUpToString:@":" intoString:&className];
    // 如果没有扫描到达终点
    if (!scanner.isAtEnd) {
        scanner.scanLocation = scanner.scanLocation + 1;
        // 扫描到 < 了，在放到 superClassName中
        [scanner scanUpToString:@"<" intoString:&superClassName];
        // 还没有扫描到终点
        if (!scanner.isAtEnd) {
            scanner.scanLocation = scanner.scanLocation + 1;
            // 扫描出 协议名
            [scanner scanUpToString:@">" intoString:&protocolNames];
        }
    }
    
    // 如果不存在父类，那么父类就是 NSObject
    if (!superClassName) superClassName = @"NSObject";
    // 修改一下类名和父类名，把前后的空白字符去掉
    className = trim(className);
    superClassName = trim(superClassName);
    
    // 把 protocol 切开拆分成数组
    NSArray *protocols = [protocolNames length] ? [protocolNames componentsSeparatedByString:@","] : nil;
    
    // 获得类名
    Class cls = NSClassFromString(className);
    // 如果不存在类名
    if (!cls) {
        // 获取父类名
        Class superCls = NSClassFromString(superClassName);
        // 如果也不存在父类名
        if (!superCls) {
            // 抛出异常
            _exceptionBlock([NSString stringWithFormat:@"can't find the super class %@", superClassName]);
            return @{@"cls": className};
        }
        // objc_allocateClassPair(类的父类，类的名字，类占的空间)
        // 创建类
        cls = objc_allocateClassPair(superCls, className.UTF8String, 0);
        // 注册类
        objc_registerClassPair(cls);
    }
    
    // 存在协议
    if (protocols.count > 0) {
        for (NSString* protocolName in protocols) {
            // 根据协议名称，获取指定协议
            Protocol *protocol = objc_getProtocol([trim(protocolName) cStringUsingEncoding:NSUTF8StringEncoding]);
            // 给 cls 添加协议
            class_addProtocol (cls, protocol);
        }
    }
    
    // 添加和重写方法
    for (int i = 0; i < 2; i ++) {
        BOOL isInstance = i == 0;
        // 0：实例方法列表 1：类方法列表
        JSValue *jsMethods = isInstance ? instanceMethods: classMethods;
        
        // 0：类对象 1：元类对象
        Class currCls = isInstance ? cls: objc_getMetaClass(className.UTF8String);
        // JSValue 转 字典
        NSDictionary *methodDict = [jsMethods toDictionary];
        for (NSString *jsMethodName in methodDict.allKeys) {
            // 通过 methodName 拿到 method 实例
            // method 实例是一个数组，第一个元素表示 method 有几个入参，第二个元素表示方法实例
            JSValue *jsMethodArr = [jsMethods valueForProperty:jsMethodName];
            // 参数个数
            int numberOfArg = [jsMethodArr[0] toInt32];
            // 把方法名中的 _ 都转为 :
            NSString *selectorName = convertJPSelectorString(jsMethodName);
            
            // 如果尾部没有 :，那么添加 :
            if ([selectorName componentsSeparatedByString:@":"].count - 1 < numberOfArg) {
                selectorName = [selectorName stringByAppendingString:@":"];
            }
            
            JSValue *jsMethod = jsMethodArr[1];
            // currCls 实现了 selectorName 的方法
            if (class_respondsToSelector(currCls, NSSelectorFromString(selectorName))) {
                // 现在的方法 替换 原来的方法
                overrideMethod(currCls, selectorName, jsMethod, !isInstance, NULL);
            } else {
                // 如果没有实现，则添加这个方法
                BOOL overrided = NO;
                for (NSString *protocolName in protocols) {
                    char *types = methodTypesInProtocol(protocolName, selectorName, isInstance, YES);
                    if (!types) types = methodTypesInProtocol(protocolName, selectorName, isInstance, NO);
                    if (types) {
                        overrideMethod(currCls, selectorName, jsMethod, !isInstance, types);
                        free(types);
                        overrided = YES;
                        break;
                    }
                }
                if (!overrided) {
                    if (![[jsMethodName substringToIndex:1] isEqualToString:@"_"]) {
                        NSMutableString *typeDescStr = [@"@@:" mutableCopy];
                        for (int i = 0; i < numberOfArg; i ++) {
                            [typeDescStr appendString:@"@"];
                        }
                        overrideMethod(currCls, selectorName, jsMethod, !isInstance, [typeDescStr cStringUsingEncoding:NSUTF8StringEncoding]);
                    }
                }
            }
        }
    }
    
    class_addMethod(cls, @selector(getProp:), (IMP)getPropIMP, "@@:@");
    class_addMethod(cls, @selector(setProp:forKey:), (IMP)setPropIMP, "v@:@@");

    return @{@"cls": className, @"superCls": superClassName};
}

// 判断这个方法是否有 js 方法的实现。 后续通过这个判断结果走原始转发流程还是走 js 方法的调用
static JSValue *getJSFunctionInObjectHierachy(id slf, NSString *selectorName)
{
    Class cls = object_getClass(slf);
    // 如果是正在在 js 中调用 oc 一个类中的 super 的方法，那么就通过 _currInvokeSuperClsName 记录下来。因为在调用的过程中由于是 super 方法，selector 会有一个 SUPER_ 的前缀。消息转发到这里的时候需要知道当前调用的其实是一个 super 的方法，需要把 SUPER_ 去除。
    if (_currInvokeSuperClsName[selectorName]) {
        cls = NSClassFromString(_currInvokeSuperClsName[selectorName]);
        selectorName = [selectorName stringByReplacingOccurrencesOfString:@"_JPSUPER_" withString:@"_JP"];
    }
    JSValue *func = _JSOverideMethods[cls][selectorName];
    // 遍历父类找这个方法
    while (!func) {
        cls = class_getSuperclass(cls);
        if (!cls) {
            return nil;
        }
        func = _JSOverideMethods[cls][selectorName];
    }
    return func;
}

// 自己的替换方法, 可以看到调用方法前两个参数一个是 self，一个是 selecter， 对应于方法签名的  @:
static void JPForwardInvocation(__unsafe_unretained id assignSlf, SEL selector, NSInvocation *invocation)
{
    
#ifdef DEBUG
    _JSLastCallStack = [NSThread callStackSymbols];
#endif
    BOOL deallocFlag = NO;
    id slf = assignSlf;
    BOOL isBlock = [[assignSlf class] isSubclassOfClass : NSClassFromString(@"NSBlock")];
    
    NSMethodSignature *methodSignature = [invocation methodSignature];
    NSInteger numberOfArguments = [methodSignature numberOfArguments];
    NSString *selectorName = isBlock ? @"" : NSStringFromSelector(invocation.selector);
    NSString *JPSelectorName = [NSString stringWithFormat:@"_JP%@", selectorName];
    // 判断 JSPSEL 是否有对应的 js 函数的实现，如果没有就原始方法的消息转发的流程
    // （被 defineClass 过的类会被替换 forwardInvocation 方法。如果有方法没有被实现，且没有被 JS重写。那么就会走原始的 forwardInvocation 要找到的是 ORIGforwardInvocation 方法）
    JSValue *jsFunc = isBlock ? objc_getAssociatedObject(assignSlf, "_JSValue")[@"cb"] : getJSFunctionInObjectHierachy(slf, JPSelectorName);
    if (!jsFunc) {
        JPExecuteORIGForwardInvocation(slf, selector, invocation);
        return;
    }
    
    // 从NSInvocation中获取调用的参数，把self与相应的参数都转换成js对象并封装到一个集合中
    // js端重写的函数，传递过来是JSValue类型，用callWithArgument:调用js方法，参数也要是js对象
    NSMutableArray *argList = [[NSMutableArray alloc] init];
    if (!isBlock) {
        if ([slf class] == slf) {
            // 如果调用的是类方法，那么给入参列表的第一个参数就是一个包含  __clsName 的 object
            [argList addObject:[JSValue valueWithObject:@{@"__clsName": NSStringFromClass([slf class])} inContext:_context]];
        } else if ([selectorName isEqualToString:@"dealloc"]) {
            // 对于被释放的对象，使用 assign 来保存 self 的指针
            // 因为在 dealloc 的时候，系统不让将 self 赋值给一个 weak 对象。（在 dealloc 的时候应该会有一些操作 weak 字典的步骤，所以不能再这个阶段再操作 weak）
            // assign 和 weak 的区别在于 assign 在指向的对象销毁的时候不会把当前指针置为 nil
            // 所以这里最终要自己确保不会在 dealloc 后调用 slf 的方法
            [argList addObject:[JPBoxing boxAssignObj:slf]];
            deallocFlag = YES;
        } else {
            // 否则用 weak 包裹
            [argList addObject:[JPBoxing boxWeakObj:slf]];
        }
    }
    
    for (NSUInteger i = isBlock ? 1 : 2; i < numberOfArguments; i++) {
        const char *argumentType = [methodSignature getArgumentTypeAtIndex:i];
        switch(argumentType[0] == 'r' ? argumentType[1] : argumentType[0]) {
        
            #define JP_FWD_ARG_CASE(_typeChar, _type) \
            case _typeChar: {   \
                _type arg;  \
                [invocation getArgument:&arg atIndex:i];    \
                [argList addObject:@(arg)]; \
                break;  \
            }
            JP_FWD_ARG_CASE('c', char)
            JP_FWD_ARG_CASE('C', unsigned char)
            JP_FWD_ARG_CASE('s', short)
            JP_FWD_ARG_CASE('S', unsigned short)
            JP_FWD_ARG_CASE('i', int)
            JP_FWD_ARG_CASE('I', unsigned int)
            JP_FWD_ARG_CASE('l', long)
            JP_FWD_ARG_CASE('L', unsigned long)
            JP_FWD_ARG_CASE('q', long long)
            JP_FWD_ARG_CASE('Q', unsigned long long)
            JP_FWD_ARG_CASE('f', float)
            JP_FWD_ARG_CASE('d', double)
            JP_FWD_ARG_CASE('B', BOOL)
            case '@': {
                __unsafe_unretained id arg;
                [invocation getArgument:&arg atIndex:i];
                if ([arg isKindOfClass:NSClassFromString(@"NSBlock")]) {
                    [argList addObject:(arg ? [arg copy]: _nilObj)];
                } else {
                    [argList addObject:(arg ? arg: _nilObj)];
                }
                break;
            }
            case '{': {
                NSString *typeString = extractStructName([NSString stringWithUTF8String:argumentType]);
                #define JP_FWD_ARG_STRUCT(_type, _transFunc) \
                if ([typeString rangeOfString:@#_type].location != NSNotFound) {    \
                    _type arg; \
                    [invocation getArgument:&arg atIndex:i];    \
                    [argList addObject:[JSValue _transFunc:arg inContext:_context]];  \
                    break; \
                }
                JP_FWD_ARG_STRUCT(CGRect, valueWithRect)
                JP_FWD_ARG_STRUCT(CGPoint, valueWithPoint)
                JP_FWD_ARG_STRUCT(CGSize, valueWithSize)
                JP_FWD_ARG_STRUCT(NSRange, valueWithRange)
                
                @synchronized (_context) {
                    NSDictionary *structDefine = _registeredStruct[typeString];
                    if (structDefine) {
                        size_t size = sizeOfStructTypes(structDefine[@"types"]);
                        if (size) {
                            void *ret = malloc(size);
                            [invocation getArgument:ret atIndex:i];
                            NSDictionary *dict = getDictOfStruct(ret, structDefine);
                            [argList addObject:[JSValue valueWithObject:dict inContext:_context]];
                            free(ret);
                            break;
                        }
                    }
                }
                
                break;
            }
            case ':': {
                SEL selector;
                [invocation getArgument:&selector atIndex:i];
                NSString *selectorName = NSStringFromSelector(selector);
                [argList addObject:(selectorName ? selectorName: _nilObj)];
                break;
            }
            case '^':
            case '*': {
                void *arg;
                [invocation getArgument:&arg atIndex:i];
                [argList addObject:[JPBoxing boxPointer:arg]];
                break;
            }
            case '#': {
                Class arg;
                [invocation getArgument:&arg atIndex:i];
                [argList addObject:[JPBoxing boxClass:arg]];
                break;
            }
            default: {
                NSLog(@"error type %s", argumentType);
                break;
            }
        }
    }
    
    // 如果当前调用的方法是 js 引起的，并且 js 调用了一个 super 的方法。那么会在 _currInvokeSuperClsName 中保存一个调用的方法名。这个方法名被加上了前缀 SUPER_。 因此真正调用的时候要把这个前缀替换为 _JP。这样才能找到保存在 JSOverrideMethods 字典中的相应方法
    if (_currInvokeSuperClsName[selectorName]) {
        Class cls = NSClassFromString(_currInvokeSuperClsName[selectorName]);
        NSString *tmpSelectorName = [[selectorName stringByReplacingOccurrencesOfString:@"_JPSUPER_" withString:@"_JP"] stringByReplacingOccurrencesOfString:@"SUPER_" withString:@"_JP"];
        // 如果父类没有重写相应的方法
        if (!_JSOverideMethods[cls][tmpSelectorName]) {
            NSString *ORIGSelectorName = [selectorName stringByReplacingOccurrencesOfString:@"SUPER_" withString:@"ORIG"];
            [argList removeObjectAtIndex:0];
            // 如果父类没有重写这个方法那么就是调用 oc 的方法，oc 直接调用父类的相应方法
            id retObj = callSelector(_currInvokeSuperClsName[selectorName], ORIGSelectorName, [JSValue valueWithObject:argList inContext:_context], [JSValue valueWithObject:@{@"__obj": slf, @"__realClsName": @""} inContext:_context], NO);
            id __autoreleasing ret = formatJSToOC([JSValue valueWithObject:retObj inContext:_context]);
            [invocation setReturnValue:&ret];
            return;
        }
    }
    
    // 转化为 js 的参数形式，将对象包裹为 {__obj: obj, __clsName: xxx} 的形式
    NSArray *params = _formatOCToJSList(argList);
    char returnType[255];
    // 获取方法的返回参数的签名
    strcpy(returnType, [methodSignature methodReturnType]);
    
    // Restore the return type
    if (strcmp(returnType, @encode(JPDouble)) == 0) {
        strcpy(returnType, @encode(double));
    }
    if (strcmp(returnType, @encode(JPFloat)) == 0) {
        strcpy(returnType, @encode(float));
    }

    // 判断 returnType 的符号签名
    switch (returnType[0] == 'r' ? returnType[1] : returnType[0]) {
        #define JP_FWD_RET_CALL_JS \
            JSValue *jsval; \
            [_JSMethodForwardCallLock lock];   \
            jsval = [jsFunc callWithArguments:params]; \
            [_JSMethodForwardCallLock unlock]; \
            while (![jsval isNull] && ![jsval isUndefined] && [jsval hasProperty:@"__isPerformInOC"]) { \
                NSArray *args = nil;  \
                JSValue *cb = jsval[@"cb"]; \
                if ([jsval hasProperty:@"sel"]) {   \
                    id callRet = callSelector(![jsval[@"clsName"] isUndefined] ? [jsval[@"clsName"] toString] : nil, [jsval[@"sel"] toString], jsval[@"args"], ![jsval[@"obj"] isUndefined] ? jsval[@"obj"] : nil, NO);  \
                    args = @[[_context[@"_formatOCToJS"] callWithArguments:callRet ? @[callRet] : _formatOCToJSList(@[_nilObj])]];  \
                }   \
                [_JSMethodForwardCallLock lock];    \
                jsval = [cb callWithArguments:args];  \
                [_JSMethodForwardCallLock unlock];  \
            }

        #define JP_FWD_RET_CASE_RET(_typeChar, _type, _retCode)   \
            case _typeChar : { \
                JP_FWD_RET_CALL_JS \
                _retCode \
                [invocation setReturnValue:&ret];\
                break;  \
            }

        #define JP_FWD_RET_CASE(_typeChar, _type, _typeSelector)   \
            JP_FWD_RET_CASE_RET(_typeChar, _type, _type ret = [[jsval toObject] _typeSelector];)   \

        #define JP_FWD_RET_CODE_ID \
            id __autoreleasing ret = formatJSToOC(jsval); \
            if (ret == _nilObj ||   \
                ([ret isKindOfClass:[NSNumber class]] && strcmp([ret objCType], "c") == 0 && ![ret boolValue])) ret = nil;  \

        #define JP_FWD_RET_CODE_POINTER    \
            void *ret; \
            id obj = formatJSToOC(jsval); \
            if ([obj isKindOfClass:[JPBoxing class]]) { \
                ret = [((JPBoxing *)obj) unboxPointer]; \
            }

        #define JP_FWD_RET_CODE_CLASS    \
            Class ret;   \
            ret = formatJSToOC(jsval);


        #define JP_FWD_RET_CODE_SEL    \
            SEL ret;   \
            id obj = formatJSToOC(jsval); \
            if ([obj isKindOfClass:[NSString class]]) { \
                ret = NSSelectorFromString(obj); \
            }

        JP_FWD_RET_CASE_RET('@', id, JP_FWD_RET_CODE_ID)
        JP_FWD_RET_CASE_RET('^', void*, JP_FWD_RET_CODE_POINTER)
        JP_FWD_RET_CASE_RET('*', void*, JP_FWD_RET_CODE_POINTER)
        JP_FWD_RET_CASE_RET('#', Class, JP_FWD_RET_CODE_CLASS)
        JP_FWD_RET_CASE_RET(':', SEL, JP_FWD_RET_CODE_SEL)

        JP_FWD_RET_CASE('c', char, charValue)
        JP_FWD_RET_CASE('C', unsigned char, unsignedCharValue)
        JP_FWD_RET_CASE('s', short, shortValue)
        JP_FWD_RET_CASE('S', unsigned short, unsignedShortValue)
        JP_FWD_RET_CASE('i', int, intValue)
        JP_FWD_RET_CASE('I', unsigned int, unsignedIntValue)
        JP_FWD_RET_CASE('l', long, longValue)
        JP_FWD_RET_CASE('L', unsigned long, unsignedLongValue)
        JP_FWD_RET_CASE('q', long long, longLongValue)
        JP_FWD_RET_CASE('Q', unsigned long long, unsignedLongLongValue)
        JP_FWD_RET_CASE('f', float, floatValue)
        JP_FWD_RET_CASE('d', double, doubleValue)
        JP_FWD_RET_CASE('B', BOOL, boolValue)

        case 'v': {
            JP_FWD_RET_CALL_JS
            break;
        }
        
        case '{': {
            NSString *typeString = extractStructName([NSString stringWithUTF8String:returnType]);
            #define JP_FWD_RET_STRUCT(_type, _funcSuffix) \
            if ([typeString rangeOfString:@#_type].location != NSNotFound) {    \
                JP_FWD_RET_CALL_JS \
                _type ret = [jsval _funcSuffix]; \
                [invocation setReturnValue:&ret];\
                break;  \
            }
            JP_FWD_RET_STRUCT(CGRect, toRect)
            JP_FWD_RET_STRUCT(CGPoint, toPoint)
            JP_FWD_RET_STRUCT(CGSize, toSize)
            JP_FWD_RET_STRUCT(NSRange, toRange)
            
            @synchronized (_context) {
                NSDictionary *structDefine = _registeredStruct[typeString];
                if (structDefine) {
                    size_t size = sizeOfStructTypes(structDefine[@"types"]);
                    JP_FWD_RET_CALL_JS
                    void *ret = malloc(size);
                    NSDictionary *dict = formatJSToOC(jsval);
                    getStructDataWithDict(ret, dict, structDefine);
                    [invocation setReturnValue:ret];
                    free(ret);
                }
            }
            break;
        }
        default: {
            break;
        }
    }
    
    if (_pointersToRelease) {
        for (NSValue *val in _pointersToRelease) {
            void *pointer = NULL;
            [val getValue:&pointer];
            CFRelease(pointer);
        }
        _pointersToRelease = nil;
    }
    
    // 这个方法是 dealloc 方法
    if (deallocFlag) {
        slf = nil;
        Class instClass = object_getClass(assignSlf);
        // 拿到 dealloc 方法实现
        Method deallocMethod = class_getInstanceMethod(instClass, NSSelectorFromString(@"ORIGdealloc"));
        void (*originalDealloc)(__unsafe_unretained id, SEL) = (__typeof__(originalDealloc))method_getImplementation(deallocMethod);
         // 调用
        originalDealloc(assignSlf, NSSelectorFromString(@"dealloc"));
    }
}

// 方法的原本的 forward 流程
static void JPExecuteORIGForwardInvocation(id slf, SEL selector, NSInvocation *invocation)
{
    // 拿到原始的被替换的 forwardInvocation： ORIDforwardInvocation, 然后调用原始的转发方法
    SEL origForwardSelector = @selector(ORIGforwardInvocation:);
    
    if ([slf respondsToSelector:origForwardSelector]) {
        NSMethodSignature *methodSignature = [slf methodSignatureForSelector:origForwardSelector];
        if (!methodSignature) {
            _exceptionBlock([NSString stringWithFormat:@"unrecognized selector -ORIGforwardInvocation: for instance %@", slf]);
            return;
        }
         // 调用原始的转换方法
        NSInvocation *forwardInv= [NSInvocation invocationWithMethodSignature:methodSignature];
        [forwardInv setTarget:slf];
        [forwardInv setSelector:origForwardSelector];
        [forwardInv setArgument:&invocation atIndex:2];
        [forwardInv invoke];
    } else {
        // 如果不存在原始的转发方法，就调用父类的转发方法
        // 这里应该是保底逻辑，一般来说，不会出现调用没有 forwardInvocation 方法的情况
        Class superCls = [[slf class] superclass];
        Method superForwardMethod = class_getInstanceMethod(superCls, @selector(forwardInvocation:));
        void (*superForwardIMP)(id, SEL, NSInvocation *);
        superForwardIMP = (void (*)(id, SEL, NSInvocation *))method_getImplementation(superForwardMethod);
        superForwardIMP(slf, @selector(forwardInvocation:), invocation);
    }
}

// 初始化 _JSOverideMethods 字典
static void _initJPOverideMethods(Class cls) {
    if (!_JSOverideMethods) {
        _JSOverideMethods = [[NSMutableDictionary alloc] init];
    }
    if (!_JSOverideMethods[cls]) {
        _JSOverideMethods[(id<NSCopying>)cls] = [[NSMutableDictionary alloc] init];
    }
}

// 重写方法
static void overrideMethod(Class cls, NSString *selectorName, JSValue *function, BOOL isClassMethod, const char *typeDescription)
{
    // 通过字符串获取SEL
    SEL selector = NSSelectorFromString(selectorName);
    
    // 没有类型签名的时候获取原方法的类型签名
    if (!typeDescription) {
        Method method = class_getInstanceMethod(cls, selector);
        typeDescription = (char *)method_getTypeEncoding(method);
    }
    
    // 获取原方法的 IMP
    IMP originalImp = class_respondsToSelector(cls, selector) ? class_getMethodImplementation(cls, selector) : NULL;
    
    // 获取消息转发处理的系统函数实现 IMP
    IMP msgForwardIMP = _objc_msgForward;
    #if !defined(__arm64__)
        if (typeDescription[0] == '{') {
            //In some cases that returns struct, we should use the '_stret' API:
            //http://sealiesoftware.com/blog/archive/2008/10/30/objc_explain_objc_msgSend_stret.html
            //NSMethodSignature knows the detail but has no API to return, we can only get the info from debugDescription.
            NSMethodSignature *methodSignature = [NSMethodSignature signatureWithObjCTypes:typeDescription];
            if ([methodSignature.debugDescription rangeOfString:@"is special struct return? YES"].location != NSNotFound) {
                msgForwardIMP = (IMP)_objc_msgForward_stret;
            }
        }
    #endif

    if (class_getMethodImplementation(cls, @selector(forwardInvocation:)) != (IMP)JPForwardInvocation) {
        // 将cls中原来 forwardInvocaiton: 的实现替换成 JPForwardInvocation:函数实现
        // originalForwardImp 为 forwardInvocation: 的实现 IMP
        IMP originalForwardImp = class_replaceMethod(cls, @selector(forwardInvocation:), (IMP)JPForwardInvocation, "v@:@");
        if (originalForwardImp) {
            // 为cls添加新的SEL(ORIGforwardInvocation:)，指向原始 forwardInvocation: 的实现IMP.
            class_addMethod(cls, @selector(ORIGforwardInvocation:), originalForwardImp, "v@:@");
        }
    }

    // 系统小于7.1，进行修复方法签名
    [cls jp_fixMethodSignature];
    // 添加一个新的方法 ORIG${原方法名} 指向 selector 的实现 IMP
    if (class_respondsToSelector(cls, selector)) {
        NSString *originalSelectorName = [NSString stringWithFormat:@"ORIG%@", selectorName];
        SEL originalSelector = NSSelectorFromString(originalSelectorName);
        if(!class_respondsToSelector(cls, originalSelector)) {
            class_addMethod(cls, originalSelector, originalImp, typeDescription);
        }
    }
    
    NSString *JPSelectorName = [NSString stringWithFormat:@"_JP%@", selectorName];
    
    // 初始化 _JSOverideMethods 字典
    _initJPOverideMethods(cls);
    // 记录新 SEL 对应 js 传过来的待替换目标方法的实现
    _JSOverideMethods[cls][JPSelectorName] = function;
    
    // Replace the original selector at last, preventing threading issus when
    // the selector get called during the execution of `overrideMethod`
    // 把原来的方法替换为 msgForward 的实现，实现方法转发
    class_replaceMethod(cls, selector, msgForwardIMP, typeDescription);
}

#pragma mark -
static id callSelector(NSString *className, NSString *selectorName, JSValue *arguments, JSValue *instance, BOOL isSuper)
{
    // realClsName 是真正要调用的类，和 clsName 的区别在于如果要调用的方法是父类方法，那么 clsName 会变为父类名，而 realClsName 仍然是子类名
    NSString *realClsName = [[instance valueForProperty:@"__realClsName"] toString];
   
    // 校验调用对象是否是类名，是否是空对象
    if (instance) {
        // js 转 oc 对象
        instance = formatJSToOC(instance);
        // 获取元类
        if (class_isMetaClass(object_getClass(instance))) {
            // 获取类名
            className = NSStringFromClass((Class)instance);
            instance = nil;
        } else if (!instance || instance == _nilObj || [instance isKindOfClass:[JPBoxing class]]) {
            return @{@"__isNil": @(YES)};
        }
    }
    
    // 把参数列表从 JS 转到 OC
    id argumentsObj = formatJSToOC(arguments);
    
    /*
     如果要执行的方法是"toJS"，即转化为js类型
     对于NSString/NSNumber/NSData 等可以直接转为 js 对象的直接转为 js 默认对象
     对于普通 oc 对象，转为 {__obj: xxx, __clsName: xxx} 的包裹形式
     */
    if (instance && [selectorName isEqualToString:@"toJS"]) {
        if ([instance isKindOfClass:[NSString class]] || [instance isKindOfClass:[NSDictionary class]] || [instance isKindOfClass:[NSArray class]] || [instance isKindOfClass:[NSDate class]]) {
            return _unboxOCObjectToJS(instance);
        }
    }

    Class cls = instance ? [instance class] : NSClassFromString(className);
    SEL selector = NSSelectorFromString(selectorName);
    
    NSString *superClassName = nil;
    if (isSuper) {
        // 创建一个 SUPER_${selectorName} 的 SEL
        NSString *superSelectorName = [NSString stringWithFormat:@"SUPER_%@", selectorName];
        SEL superSelector = NSSelectorFromString(superSelectorName);
        
        // 通过 js 传来的 realClsName 拿到 superCls
        Class superCls;
        if (realClsName.length) {
            Class defineClass = NSClassFromString(realClsName);
            // 如果 realClsName 的父类能找到就用 realClsName 的父类，否则就直接用传过来的 className 转的 cls
            superCls = defineClass ? [defineClass superclass] : [cls superclass];
        } else {
            superCls = [cls superclass];
        }
        
        // 获取 superCls 对应的原始方法的函数指针
        Method superMethod = class_getInstanceMethod(superCls, selector);
        IMP superIMP = method_getImplementation(superMethod);
        
        // 给当前的 class 添加一个 superSelector, 形式为 SUPER_XXX 的形式，这个方法的指针指向父类方法
        // 之所以给子类添加一个指向父类实现的方法是因为 OC 中调用父类方法调用者也是子类，是通过转发（superclass指针）调用到父类实现的。
        // 这里就是模拟了这个过程，直接给子类添加父类实现的方法
        class_addMethod(cls, superSelector, superIMP, method_getTypeEncoding(superMethod));
        
        // 因为是给子类动态添加的 ${SUPER_XXX} 的方法，它的实现是指向父类相应的原始方法。如果父类的方法被 JS 重写了，那么 ${SUPER_XXX} 也应该被 JS 重写。所以这里要对 ${SUPER_XXX} 的方法进行 JS 的替换
        NSString *JPSelectorName = [NSString stringWithFormat:@"_JP%@", selectorName];
        JSValue *overideFunction = _JSOverideMethods[superCls][JPSelectorName];
        if (overideFunction) {
            overrideMethod(cls, superSelectorName, overideFunction, NO, NULL);
        }
        
        selector = superSelector;
        superClassName = NSStringFromClass(superCls);
    }
    
    
    NSMutableArray *_markArray;
    
    // 创建 NSInvocation
    NSInvocation *invocation;
    NSMethodSignature *methodSignature;
    if (!_JSMethodSignatureCache) {
        _JSMethodSignatureCache = [[NSMutableDictionary alloc]init];
    }
    if (instance) {
        // 如果是对象方法
        [_JSMethodSignatureLock lock];
        if (!_JSMethodSignatureCache[cls]) {
            _JSMethodSignatureCache[(id<NSCopying>)cls] = [[NSMutableDictionary alloc]init];
        }
        methodSignature = _JSMethodSignatureCache[cls][selectorName];
        if (!methodSignature) {
            methodSignature = [cls instanceMethodSignatureForSelector:selector];
            methodSignature = fixSignature(methodSignature);
            _JSMethodSignatureCache[cls][selectorName] = methodSignature;
        }
        [_JSMethodSignatureLock unlock];
        if (!methodSignature) {
            _exceptionBlock([NSString stringWithFormat:@"unrecognized selector %@ for instance %@", selectorName, instance]);
            return nil;
        }
        // 创建 NSInvocation
        invocation = [NSInvocation invocationWithMethodSignature:methodSignature];
        // 设置消息发送的目标对象
        [invocation setTarget:instance];
    } else {
        // 如果是类方法，直接获取函数签名
        methodSignature = [cls methodSignatureForSelector:selector];
        methodSignature = fixSignature(methodSignature);
        if (!methodSignature) {
            _exceptionBlock([NSString stringWithFormat:@"unrecognized selector %@ for class %@", selectorName, className]);
            return nil;
        }
        invocation= [NSInvocation invocationWithMethodSignature:methodSignature];
        [invocation setTarget:cls];
    }
    // 设置 NSInvocation 的 SEL
    [invocation setSelector:selector];
    
    // 处理可变参数
    NSUInteger numberOfArguments = methodSignature.numberOfArguments;
    NSInteger inputArguments = [(NSArray *)argumentsObj count];
    // 针对可变参数个数的方法。参数个数会大于方法签名的参数的个数就是可变参数方法
    if (inputArguments > numberOfArguments - 2) {
        // calling variable argument method, only support parameter type `id` and return type `id`
        // // 只支持参数都是 id 类型，并且返回类型也是 id 类型。
        id sender = instance != nil ? instance : cls;
        id result = invokeVariableParameterMethod(argumentsObj, methodSignature, sender, selector);
        return formatOCToJS(result);
    }
    
    for (NSUInteger i = 2; i < numberOfArguments; i++) {
        const char *argumentType = [methodSignature getArgumentTypeAtIndex:i];
        id valObj = argumentsObj[i-2];
        // 根据 argumentType 表示的类型，设置 NSInvocation 的参数类型
        switch (argumentType[0] == 'r' ? argumentType[1] : argumentType[0]) {
                
                // 判断是否是当前的 type，如果是，就设置 invocation 的第 i 个元素设置为该类型，值为 valObj
                #define JP_CALL_ARG_CASE(_typeString, _type, _selector) \
                case _typeString: {                              \
                    _type value = [valObj _selector];                     \
                    [invocation setArgument:&value atIndex:i];\
                    break; \
                }
                
                JP_CALL_ARG_CASE('c', char, charValue)
                JP_CALL_ARG_CASE('C', unsigned char, unsignedCharValue)
                JP_CALL_ARG_CASE('s', short, shortValue)
                JP_CALL_ARG_CASE('S', unsigned short, unsignedShortValue)
                JP_CALL_ARG_CASE('i', int, intValue)
                JP_CALL_ARG_CASE('I', unsigned int, unsignedIntValue)
                JP_CALL_ARG_CASE('l', long, longValue)
                JP_CALL_ARG_CASE('L', unsigned long, unsignedLongValue)
                JP_CALL_ARG_CASE('q', long long, longLongValue)
                JP_CALL_ARG_CASE('Q', unsigned long long, unsignedLongLongValue)
                JP_CALL_ARG_CASE('f', float, floatValue)
                JP_CALL_ARG_CASE('d', double, doubleValue)
                JP_CALL_ARG_CASE('B', BOOL, boolValue)
                
            // selector类型
            case ':': {
                SEL value = nil;
                if (valObj != _nilObj) {
                    value = NSSelectorFromString(valObj);
                }
                [invocation setArgument:&value atIndex:i];
                break;
            }
            // 结构体类型
            case '{': {
                // 获取结构体名
                NSString *typeString = extractStructName([NSString stringWithUTF8String:argumentType]);
                // 去除 js 的参数
                JSValue *val = arguments[i-2];
                // 如果结构体是给定的类型，那么就把 js 的参数转化为该类型的结构体设置到 invocation 中去
                #define JP_CALL_ARG_STRUCT(_type, _methodName) \
                if ([typeString rangeOfString:@#_type].location != NSNotFound) {    \
                    _type value = [val _methodName];  \
                    [invocation setArgument:&value atIndex:i];  \
                    break; \
                }
                // 校验是否是 Rect，Point，Size，Range 四种结构体
                JP_CALL_ARG_STRUCT(CGRect, toRect)
                JP_CALL_ARG_STRUCT(CGPoint, toPoint)
                JP_CALL_ARG_STRUCT(CGSize, toSize)
                JP_CALL_ARG_STRUCT(NSRange, toRange)
                @synchronized (_context) {
                    // 检查是否是通过 defineStruct 定义的结构体
                    // 结构体包含的键为 types 结构体的类型，keys 结构体的键
                    NSDictionary *structDefine = _registeredStruct[typeString];
                    if (structDefine) {
                        // 获取结构体的大小
                        size_t size = sizeOfStructTypes(structDefine[@"types"]);
                        // 创建相应大小的内存地址
                        void *ret = malloc(size);
                        // 把 valObj 里的数据复制到 ret 上
                        getStructDataWithDict(ret, valObj, structDefine);
                        // 设置 ret 为 invocation 的参数
                        [invocation setArgument:ret atIndex:i];
                        free(ret);
                        break;
                    }
                }
                
                break;
            }
            // 指针类型
            case '*':
            case '^': {
                // 如果是 JPBoxing 类型，那么解包，如果不是 JPBoxing 类型，那么继续往下走
                if ([valObj isKindOfClass:[JPBoxing class]]) {
                    void *value = [((JPBoxing *)valObj) unboxPointer];
                    
                    // ^@ 表示一个指向id类型的指针
                    if (argumentType[1] == '@') {
                        if (!_TMPMemoryPool) {
                            _TMPMemoryPool = [[NSMutableDictionary alloc] init];
                        }
                        if (!_markArray) {
                            _markArray = [[NSMutableArray alloc] init];
                        }
                        memset(value, 0, sizeof(id));
                        // 把 JPBoxing 放到 markArray 数组中
                        [_markArray addObject:valObj];
                    }
                    
                    [invocation setArgument:&value atIndex:i];
                    break;
                }
            }
            // class 类型
            case '#': {
                // 如果是 JPBoxing 类型那么解包，如果不是那么继续往下走
                if ([valObj isKindOfClass:[JPBoxing class]]) {
                    Class value = [((JPBoxing *)valObj) unboxClass];
                    [invocation setArgument:&value atIndex:i];
                    break;
                }
            }
            default: {
                // null 类型
                if (valObj == _nullObj) {
                    valObj = [NSNull null];
                    [invocation setArgument:&valObj atIndex:i];
                    break;
                }
                if (valObj == _nilObj ||
                    ([valObj isKindOfClass:[NSNumber class]] && strcmp([valObj objCType], "c") == 0 && ![valObj boolValue])) {
                    valObj = nil;
                    [invocation setArgument:&valObj atIndex:i];
                    break;
                }
                // block 类型
                if ([(JSValue *)arguments[i-2] hasProperty:@"__isBlock"]) {
                    JSValue *blkJSVal = arguments[i-2];
                    Class JPBlockClass = NSClassFromString(@"JPBlock");
                    if (JPBlockClass && ![blkJSVal[@"blockObj"] isUndefined]) {
                        __autoreleasing id cb = [JPBlockClass performSelector:@selector(blockWithBlockObj:) withObject:[blkJSVal[@"blockObj"] toObject]];
                        [invocation setArgument:&cb atIndex:i];
                        Block_release((__bridge void *)cb);
                    } else {
                        __autoreleasing id cb = genCallbackBlock(arguments[i-2]);
                        [invocation setArgument:&cb atIndex:i];
                    }
                } else {
                    [invocation setArgument:&valObj atIndex:i];
                }
            }
        }
    }
    
    // 如果执行的是子类，那么在 _currInvokeSuperClsName 中保存
    if (superClassName) _currInvokeSuperClsName[selectorName] = superClassName;
    // 执行方法
    [invocation invoke];
    // 执行完方法后从 _currInvokeSuperClsName 移除
    if (superClassName) [_currInvokeSuperClsName removeObjectForKey:selectorName];
    if ([_markArray count] > 0) {
        for (JPBoxing *box in _markArray) {
            // pointer 是一个二级指针
            // 执行完方法后，二级指针会被指向一个指针
            void *pointer = [box unboxPointer];
            // 让 obj 指向二级指针 pointer 指向的指针指向的值
            id obj = *((__unsafe_unretained id *)pointer);
            if (obj) {
                @synchronized(_TMPMemoryPool) {
                    // 如果二级指针指向的地址确实存在，那么就把 obj 暂时保存起来，防止被回收了。
                    // 因为上面的 obj 是 unsafe_unretained 的
                    [_TMPMemoryPool setObject:obj forKey:[NSNumber numberWithInteger:[(NSObject*)obj hash]]];
                }
            }
        }
    }
    
    char returnType[255];
    strcpy(returnType, [methodSignature methodReturnType]);
    
    // Restore the return type
    if (strcmp(returnType, @encode(JPDouble)) == 0) {
        strcpy(returnType, @encode(double));
    }
    if (strcmp(returnType, @encode(JPFloat)) == 0) {
        strcpy(returnType, @encode(float));
    }

    id returnValue;
    // 不是 void 类型
    // strncmp 判断字符串是否相等
    if (strncmp(returnType, "v", 1) != 0) {
        if (strncmp(returnType, "@", 1) == 0) {
            void *result;
            // 拿到返回值
            [invocation getReturnValue:&result];
            
            //For performance, ignore the other methods prefix with alloc/new/copy/mutableCopy
            if ([selectorName isEqualToString:@"alloc"] || [selectorName isEqualToString:@"new"] ||
                [selectorName isEqualToString:@"copy"] || [selectorName isEqualToString:@"mutableCopy"]) {
                // 针对 alloc 等方法，需要通过 __bridge_transfer 减去引用计数
                returnValue = (__bridge_transfer id)result;
            } else {
                returnValue = (__bridge id)result;
            }
             // 将 OC 转为 JS 返回
            return formatOCToJS(returnValue);
            
        } else {
            // 其他的各种类型 返回 JSValue
            switch (returnType[0] == 'r' ? returnType[1] : returnType[0]) {
                    
                #define JP_CALL_RET_CASE(_typeString, _type) \
                case _typeString: {                              \
                    _type tempResultSet; \
                    [invocation getReturnValue:&tempResultSet];\
                    returnValue = @(tempResultSet); \
                    break; \
                }
                    
                JP_CALL_RET_CASE('c', char)
                JP_CALL_RET_CASE('C', unsigned char)
                JP_CALL_RET_CASE('s', short)
                JP_CALL_RET_CASE('S', unsigned short)
                JP_CALL_RET_CASE('i', int)
                JP_CALL_RET_CASE('I', unsigned int)
                JP_CALL_RET_CASE('l', long)
                JP_CALL_RET_CASE('L', unsigned long)
                JP_CALL_RET_CASE('q', long long)
                JP_CALL_RET_CASE('Q', unsigned long long)
                JP_CALL_RET_CASE('f', float)
                JP_CALL_RET_CASE('d', double)
                JP_CALL_RET_CASE('B', BOOL)

                case '{': {
                    NSString *typeString = extractStructName([NSString stringWithUTF8String:returnType]);
                    #define JP_CALL_RET_STRUCT(_type, _methodName) \
                    if ([typeString rangeOfString:@#_type].location != NSNotFound) {    \
                        _type result;   \
                        [invocation getReturnValue:&result];    \
                        return [JSValue _methodName:result inContext:_context];    \
                    }
                    JP_CALL_RET_STRUCT(CGRect, valueWithRect)
                    JP_CALL_RET_STRUCT(CGPoint, valueWithPoint)
                    JP_CALL_RET_STRUCT(CGSize, valueWithSize)
                    JP_CALL_RET_STRUCT(NSRange, valueWithRange)
                    @synchronized (_context) {
                        NSDictionary *structDefine = _registeredStruct[typeString];
                        if (structDefine) {
                            size_t size = sizeOfStructTypes(structDefine[@"types"]);
                            void *ret = malloc(size);
                            [invocation getReturnValue:ret];
                            NSDictionary *dict = getDictOfStruct(ret, structDefine);
                            free(ret);
                            return dict;
                        }
                    }
                    break;
                }
                case '*':
                case '^': {
                    void *result;
                    [invocation getReturnValue:&result];
                    returnValue = formatOCToJS([JPBoxing boxPointer:result]);
                    if (strncmp(returnType, "^{CG", 4) == 0) {
                        if (!_pointersToRelease) {
                            _pointersToRelease = [[NSMutableArray alloc] init];
                        }
                        [_pointersToRelease addObject:[NSValue valueWithPointer:result]];
                        CFRetain(result);
                    }
                    break;
                }
                case '#': {
                    Class result;
                    [invocation getReturnValue:&result];
                    returnValue = formatOCToJS([JPBoxing boxClass:result]);
                    break;
                }
            }
            return returnValue;
        }
    }
    return nil;
}

static id (*new_msgSend1)(id, SEL, id,...) = (id (*)(id, SEL, id,...)) objc_msgSend;
static id (*new_msgSend2)(id, SEL, id, id,...) = (id (*)(id, SEL, id, id,...)) objc_msgSend;
static id (*new_msgSend3)(id, SEL, id, id, id,...) = (id (*)(id, SEL, id, id, id,...)) objc_msgSend;
static id (*new_msgSend4)(id, SEL, id, id, id, id,...) = (id (*)(id, SEL, id, id, id, id,...)) objc_msgSend;
static id (*new_msgSend5)(id, SEL, id, id, id, id, id,...) = (id (*)(id, SEL, id, id, id, id, id,...)) objc_msgSend;
static id (*new_msgSend6)(id, SEL, id, id, id, id, id, id,...) = (id (*)(id, SEL, id, id, id, id, id, id,...)) objc_msgSend;
static id (*new_msgSend7)(id, SEL, id, id, id, id, id, id, id,...) = (id (*)(id, SEL, id, id, id, id, id, id,id,...)) objc_msgSend;
static id (*new_msgSend8)(id, SEL, id, id, id, id, id, id, id, id,...) = (id (*)(id, SEL, id, id, id, id, id, id, id, id,...)) objc_msgSend;
static id (*new_msgSend9)(id, SEL, id, id, id, id, id, id, id, id, id,...) = (id (*)(id, SEL, id, id, id, id, id, id, id, id, id, ...)) objc_msgSend;
static id (*new_msgSend10)(id, SEL, id, id, id, id, id, id, id, id, id, id,...) = (id (*)(id, SEL, id, id, id, id, id, id, id, id, id, id,...)) objc_msgSend;

static id invokeVariableParameterMethod(NSMutableArray *origArgumentsList, NSMethodSignature *methodSignature, id sender, SEL selector) {
    
    NSInteger inputArguments = [(NSArray *)origArgumentsList count];
    NSUInteger numberOfArguments = methodSignature.numberOfArguments;
    
    NSMutableArray *argumentsList = [[NSMutableArray alloc] init];
    for (NSUInteger j = 0; j < inputArguments; j++) {
        NSInteger index = MIN(j + 2, numberOfArguments - 1);
        const char *argumentType = [methodSignature getArgumentTypeAtIndex:index];
        id valObj = origArgumentsList[j];
        char argumentTypeChar = argumentType[0] == 'r' ? argumentType[1] : argumentType[0];
        if (argumentTypeChar == '@') {
            [argumentsList addObject:valObj];
        } else {
            return nil;
        }
    }
    
    id results = nil;
    numberOfArguments = numberOfArguments - 2;
    
    //If you want to debug the macro code below, replace it to the expanded code:
    //https://gist.github.com/bang590/ca3720ae1da594252a2e
    #define JP_G_ARG(_idx) getArgument(argumentsList[_idx])
    #define JP_CALL_MSGSEND_ARG1(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0));
    #define JP_CALL_MSGSEND_ARG2(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0), JP_G_ARG(1));
    #define JP_CALL_MSGSEND_ARG3(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0), JP_G_ARG(1), JP_G_ARG(2));
    #define JP_CALL_MSGSEND_ARG4(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0), JP_G_ARG(1), JP_G_ARG(2), JP_G_ARG(3));
    #define JP_CALL_MSGSEND_ARG5(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0), JP_G_ARG(1), JP_G_ARG(2), JP_G_ARG(3), JP_G_ARG(4));
    #define JP_CALL_MSGSEND_ARG6(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0), JP_G_ARG(1), JP_G_ARG(2), JP_G_ARG(3), JP_G_ARG(4), JP_G_ARG(5));
    #define JP_CALL_MSGSEND_ARG7(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0), JP_G_ARG(1), JP_G_ARG(2), JP_G_ARG(3), JP_G_ARG(4), JP_G_ARG(5), JP_G_ARG(6));
    #define JP_CALL_MSGSEND_ARG8(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0), JP_G_ARG(1), JP_G_ARG(2), JP_G_ARG(3), JP_G_ARG(4), JP_G_ARG(5), JP_G_ARG(6), JP_G_ARG(7));
    #define JP_CALL_MSGSEND_ARG9(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0), JP_G_ARG(1), JP_G_ARG(2), JP_G_ARG(3), JP_G_ARG(4), JP_G_ARG(5), JP_G_ARG(6), JP_G_ARG(7), JP_G_ARG(8));
    #define JP_CALL_MSGSEND_ARG10(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0), JP_G_ARG(1), JP_G_ARG(2), JP_G_ARG(3), JP_G_ARG(4), JP_G_ARG(5), JP_G_ARG(6), JP_G_ARG(7), JP_G_ARG(8), JP_G_ARG(9));
    #define JP_CALL_MSGSEND_ARG11(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0), JP_G_ARG(1), JP_G_ARG(2), JP_G_ARG(3), JP_G_ARG(4), JP_G_ARG(5), JP_G_ARG(6), JP_G_ARG(7), JP_G_ARG(8), JP_G_ARG(9), JP_G_ARG(10));
        
    #define JP_IF_REAL_ARG_COUNT(_num) if([argumentsList count] == _num)

    #define JP_DEAL_MSGSEND(_realArgCount, _defineArgCount) \
        if(numberOfArguments == _defineArgCount) { \
            JP_CALL_MSGSEND_ARG##_realArgCount(_defineArgCount) \
        }
    
    JP_IF_REAL_ARG_COUNT(1) { JP_CALL_MSGSEND_ARG1(1) }
    JP_IF_REAL_ARG_COUNT(2) { JP_DEAL_MSGSEND(2, 1) JP_DEAL_MSGSEND(2, 2) }
    JP_IF_REAL_ARG_COUNT(3) { JP_DEAL_MSGSEND(3, 1) JP_DEAL_MSGSEND(3, 2) JP_DEAL_MSGSEND(3, 3) }
    JP_IF_REAL_ARG_COUNT(4) { JP_DEAL_MSGSEND(4, 1) JP_DEAL_MSGSEND(4, 2) JP_DEAL_MSGSEND(4, 3) JP_DEAL_MSGSEND(4, 4) }
    JP_IF_REAL_ARG_COUNT(5) { JP_DEAL_MSGSEND(5, 1) JP_DEAL_MSGSEND(5, 2) JP_DEAL_MSGSEND(5, 3) JP_DEAL_MSGSEND(5, 4) JP_DEAL_MSGSEND(5, 5) }
    JP_IF_REAL_ARG_COUNT(6) { JP_DEAL_MSGSEND(6, 1) JP_DEAL_MSGSEND(6, 2) JP_DEAL_MSGSEND(6, 3) JP_DEAL_MSGSEND(6, 4) JP_DEAL_MSGSEND(6, 5) JP_DEAL_MSGSEND(6, 6) }
    JP_IF_REAL_ARG_COUNT(7) { JP_DEAL_MSGSEND(7, 1) JP_DEAL_MSGSEND(7, 2) JP_DEAL_MSGSEND(7, 3) JP_DEAL_MSGSEND(7, 4) JP_DEAL_MSGSEND(7, 5) JP_DEAL_MSGSEND(7, 6) JP_DEAL_MSGSEND(7, 7) }
    JP_IF_REAL_ARG_COUNT(8) { JP_DEAL_MSGSEND(8, 1) JP_DEAL_MSGSEND(8, 2) JP_DEAL_MSGSEND(8, 3) JP_DEAL_MSGSEND(8, 4) JP_DEAL_MSGSEND(8, 5) JP_DEAL_MSGSEND(8, 6) JP_DEAL_MSGSEND(8, 7) JP_DEAL_MSGSEND(8, 8) }
    JP_IF_REAL_ARG_COUNT(9) { JP_DEAL_MSGSEND(9, 1) JP_DEAL_MSGSEND(9, 2) JP_DEAL_MSGSEND(9, 3) JP_DEAL_MSGSEND(9, 4) JP_DEAL_MSGSEND(9, 5) JP_DEAL_MSGSEND(9, 6) JP_DEAL_MSGSEND(9, 7) JP_DEAL_MSGSEND(9, 8) JP_DEAL_MSGSEND(9, 9) }
    JP_IF_REAL_ARG_COUNT(10) { JP_DEAL_MSGSEND(10, 1) JP_DEAL_MSGSEND(10, 2) JP_DEAL_MSGSEND(10, 3) JP_DEAL_MSGSEND(10, 4) JP_DEAL_MSGSEND(10, 5) JP_DEAL_MSGSEND(10, 6) JP_DEAL_MSGSEND(10, 7) JP_DEAL_MSGSEND(10, 8) JP_DEAL_MSGSEND(10, 9) JP_DEAL_MSGSEND(10, 10) }
    
    return results;
}

NSMethodSignature *block_methodSignatureForSelector(id self, SEL _cmd, SEL aSelector) {
    uint8_t *p = (uint8_t *)((__bridge void *)self);
    p += sizeof(void *) * 2 + sizeof(int32_t) *2 + sizeof(uintptr_t) * 2;
    const char **signature = (const char **)p;
    return [NSMethodSignature signatureWithObjCTypes:*signature];
}


static id getArgument(id valObj){
    if (valObj == _nilObj ||
        ([valObj isKindOfClass:[NSNumber class]] && strcmp([valObj objCType], "c") == 0 && ![valObj boolValue])) {
        return nil;
    }
    return valObj;
}

#pragma mark -

static id genCallbackBlock(JSValue *jsVal)
{
    // 创建空的 block 实例
    void (^block)(void) = ^(void){};
    // 拿 p 指向刚刚创建的 block
    uint8_t *p = (uint8_t *)((__bridge void *)block);
    // 根据 block 的内存分布，增加了一个 void* 和 2个 int 之后， p 指向的是 invoke 方法
    p += sizeof(void *) + sizeof(int32_t) *2;
    // 新建一个二级指针 invoke 指向 p 的当前位置
    void(**invoke)(void) = (void (**)(void))p;
    
    // p 再增加一个 void* 和两个 ptr 的大小，p指向的的是 signature
    // hook 的 block 一定是个不使用外部变量的全局 block，所以没有 copy 和 dispose 函数。因此直接满足下面的公式
    p += sizeof(void *) + sizeof(uintptr_t) * 2;
    // 新建一个二级指针 signature 指向 p 的当前位置
    const char **signature = (const char **)p;
    
    static NSMutableDictionary *typeSignatureDict;
    if (!typeSignatureDict) {
        typeSignatureDict  = [NSMutableDictionary new];
        // 把各个类型的签名都存放到 typeSignatureDict 字典中
        #define JP_DEFINE_TYPE_SIGNATURE(_type) \
        [typeSignatureDict setObject:@[[NSString stringWithUTF8String:@encode(_type)], @(sizeof(_type))] forKey:@#_type];\

        JP_DEFINE_TYPE_SIGNATURE(id);
        JP_DEFINE_TYPE_SIGNATURE(BOOL);
        JP_DEFINE_TYPE_SIGNATURE(int);
        JP_DEFINE_TYPE_SIGNATURE(void);
        JP_DEFINE_TYPE_SIGNATURE(char);
        JP_DEFINE_TYPE_SIGNATURE(short);
        JP_DEFINE_TYPE_SIGNATURE(unsigned short);
        JP_DEFINE_TYPE_SIGNATURE(unsigned int);
        JP_DEFINE_TYPE_SIGNATURE(long);
        JP_DEFINE_TYPE_SIGNATURE(unsigned long);
        JP_DEFINE_TYPE_SIGNATURE(long long);
        JP_DEFINE_TYPE_SIGNATURE(unsigned long long);
        JP_DEFINE_TYPE_SIGNATURE(float);
        JP_DEFINE_TYPE_SIGNATURE(double);
        JP_DEFINE_TYPE_SIGNATURE(bool);
        JP_DEFINE_TYPE_SIGNATURE(size_t);
        JP_DEFINE_TYPE_SIGNATURE(CGFloat);
        JP_DEFINE_TYPE_SIGNATURE(CGSize);
        JP_DEFINE_TYPE_SIGNATURE(CGRect);
        JP_DEFINE_TYPE_SIGNATURE(CGPoint);
        JP_DEFINE_TYPE_SIGNATURE(CGVector);
        JP_DEFINE_TYPE_SIGNATURE(NSRange);
        JP_DEFINE_TYPE_SIGNATURE(NSInteger);
        JP_DEFINE_TYPE_SIGNATURE(Class);
        JP_DEFINE_TYPE_SIGNATURE(SEL);
        JP_DEFINE_TYPE_SIGNATURE(void*);
        JP_DEFINE_TYPE_SIGNATURE(void *);
    }
    
    // 拿到创建 block 时传过来的参数数组
    NSString *types = [jsVal[@"args"] toString];
    // 传过来的参数数组以 , 分割
    NSArray *lt = [types componentsSeparatedByString:@","];
    
    // block 的函数签名不是 @: 而是 @?
    NSString *funcSignature = @"@?0";
    
    NSInteger size = sizeof(void *);
    // for 循环，把 args 中的类型对应的签名都拿到，然后设置到 funcSignature 中。
    for (NSInteger i = 1; i < lt.count;) {
        NSString *t = trim(lt[i]);
        NSString *tpe = typeSignatureDict[typeSignatureDict[t] ? t : @"id"][0];
        if (i == 0) {
            funcSignature  =[[NSString stringWithFormat:@"%@%@",tpe, [@(size) stringValue]] stringByAppendingString:funcSignature];
            break;
        }
        
        funcSignature = [funcSignature stringByAppendingString:[NSString stringWithFormat:@"%@%@", tpe, [@(size) stringValue]]];
        size += [typeSignatureDict[typeSignatureDict[t] ? t : @"id"][1] integerValue];
        
        i = (i != lt.count - 1) ? i + 1 : 0;
    }
    
    IMP msgForwardIMP = _objc_msgForward;
#if !defined(__arm64__)
    if ([funcSignature UTF8String][0] == '{') {
        //In some cases that returns struct, we should use the '_stret' API:
        //http://sealiesoftware.com/blog/archive/2008/10/30/objc_explain_objc_msgSend_stret.html
        //NSMethodSignature knows the detail but has no API to return, we can only get the info from debugDescription.
        NSMethodSignature *methodSignature = [NSMethodSignature signatureWithObjCTypes:[funcSignature UTF8String]];
        if ([methodSignature.debugDescription rangeOfString:@"is special struct return? YES"].location != NSNotFound) {
            msgForwardIMP = (IMP)_objc_msgForward_stret;
        }
    }
#endif
    // 将当前 block 的方法实现指针指向 _objc_msgForward
    *invoke = (void *)msgForwardIMP;
    
    const char *fs = [funcSignature UTF8String];
    char *s = malloc(strlen(fs));
    strcpy(s, fs);
    // 将 block 的签名指向新生成的签名
    *signature = s;
    
    // 将 js 端传来的函数实现以 _JSValue 的关联属性的方式保存在 block 中
    objc_setAssociatedObject(block, "_JSValue", jsVal, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 获取 NSBlock 的 class
        Class cls = NSClassFromString(@"NSBlock");
        // 要 hook block 就要替换 NSBlock 的 forwardInvocation 和 methodSignatureForSelector 方法
#define JP_HOOK_METHOD(selector, func) {Method method = class_getInstanceMethod([NSObject class], selector); \
BOOL success = class_addMethod(cls, selector, (IMP)func, method_getTypeEncoding(method)); \
if (!success) { class_replaceMethod(cls, selector, (IMP)func, method_getTypeEncoding(method));}}
        
        JP_HOOK_METHOD(@selector(methodSignatureForSelector:), block_methodSignatureForSelector);
        JP_HOOK_METHOD(@selector(forwardInvocation:), JPForwardInvocation);
    });
    
    return block;
}

#pragma mark - Struct

static int sizeOfStructTypes(NSString *structTypes)
{
    const char *types = [structTypes cStringUsingEncoding:NSUTF8StringEncoding];
    int index = 0;
    int size = 0;
    while (types[index]) {
        switch (types[index]) {
            #define JP_STRUCT_SIZE_CASE(_typeChar, _type)   \
            case _typeChar: \
                size += sizeof(_type);  \
                break;
                
            JP_STRUCT_SIZE_CASE('c', char)
            JP_STRUCT_SIZE_CASE('C', unsigned char)
            JP_STRUCT_SIZE_CASE('s', short)
            JP_STRUCT_SIZE_CASE('S', unsigned short)
            JP_STRUCT_SIZE_CASE('i', int)
            JP_STRUCT_SIZE_CASE('I', unsigned int)
            JP_STRUCT_SIZE_CASE('l', long)
            JP_STRUCT_SIZE_CASE('L', unsigned long)
            JP_STRUCT_SIZE_CASE('q', long long)
            JP_STRUCT_SIZE_CASE('Q', unsigned long long)
            JP_STRUCT_SIZE_CASE('f', float)
            JP_STRUCT_SIZE_CASE('F', CGFloat)
            JP_STRUCT_SIZE_CASE('N', NSInteger)
            JP_STRUCT_SIZE_CASE('U', NSUInteger)
            JP_STRUCT_SIZE_CASE('d', double)
            JP_STRUCT_SIZE_CASE('B', BOOL)
            JP_STRUCT_SIZE_CASE('*', void *)
            JP_STRUCT_SIZE_CASE('^', void *)
                
            case '{': {
                NSString *structTypeStr = [structTypes substringFromIndex:index];
                NSUInteger end = [structTypeStr rangeOfString:@"}"].location;
                if (end != NSNotFound) {
                    NSString *subStructName = [structTypeStr substringWithRange:NSMakeRange(1, end - 1)];
                    NSDictionary *subStructDefine = [JPExtension registeredStruct][subStructName];
                    NSString *subStructTypes = subStructDefine[@"types"];
                    size += sizeOfStructTypes(subStructTypes);
                    index += (int)end;
                    break;
                }
            }
            
            default:
                break;
        }
        index ++;
    }
    return size;
}

static void getStructDataWithDict(void *structData, NSDictionary *dict, NSDictionary *structDefine)
{
    NSArray *itemKeys = structDefine[@"keys"];
    const char *structTypes = [structDefine[@"types"] cStringUsingEncoding:NSUTF8StringEncoding];
    int position = 0;
    for (NSString *itemKey in itemKeys) {
        switch(*structTypes) {
            #define JP_STRUCT_DATA_CASE(_typeStr, _type, _transMethod) \
            case _typeStr: { \
                int size = sizeof(_type);    \
                _type val = [dict[itemKey] _transMethod];   \
                memcpy(structData + position, &val, size);  \
                position += size;    \
                break;  \
            }
                
            JP_STRUCT_DATA_CASE('c', char, charValue)
            JP_STRUCT_DATA_CASE('C', unsigned char, unsignedCharValue)
            JP_STRUCT_DATA_CASE('s', short, shortValue)
            JP_STRUCT_DATA_CASE('S', unsigned short, unsignedShortValue)
            JP_STRUCT_DATA_CASE('i', int, intValue)
            JP_STRUCT_DATA_CASE('I', unsigned int, unsignedIntValue)
            JP_STRUCT_DATA_CASE('l', long, longValue)
            JP_STRUCT_DATA_CASE('L', unsigned long, unsignedLongValue)
            JP_STRUCT_DATA_CASE('q', long long, longLongValue)
            JP_STRUCT_DATA_CASE('Q', unsigned long long, unsignedLongLongValue)
            JP_STRUCT_DATA_CASE('f', float, floatValue)
            JP_STRUCT_DATA_CASE('F', CGFloat, CGFloatValue)
            JP_STRUCT_DATA_CASE('d', double, doubleValue)
            JP_STRUCT_DATA_CASE('B', BOOL, boolValue)
            JP_STRUCT_DATA_CASE('N', NSInteger, integerValue)
            JP_STRUCT_DATA_CASE('U', NSUInteger, unsignedIntegerValue)
            
            case '*':
            case '^': {
                int size = sizeof(void *);
                void *val = [(JPBoxing *)dict[itemKey] unboxPointer];
                memcpy(structData + position, &val, size);
                break;
            }
            case '{': {
                NSString *subStructName = [NSString stringWithCString:structTypes encoding:NSASCIIStringEncoding];
                NSUInteger end = [subStructName rangeOfString:@"}"].location;
                if (end != NSNotFound) {
                    subStructName = [subStructName substringWithRange:NSMakeRange(1, end - 1)];
                    NSDictionary *subStructDefine = [JPExtension registeredStruct][subStructName];
                    NSDictionary *subDict = dict[itemKey];
                    int size = sizeOfStructTypes(subStructDefine[@"types"]);
                    getStructDataWithDict(structData + position, subDict, subStructDefine);
                    position += size;
                    structTypes += end;
                    break;
                }
            }
            default:
                break;
            
        }
        structTypes ++;
    }
}

static NSDictionary *getDictOfStruct(void *structData, NSDictionary *structDefine)
{
    NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
    NSArray *itemKeys = structDefine[@"keys"];
    const char *structTypes = [structDefine[@"types"] cStringUsingEncoding:NSUTF8StringEncoding];
    int position = 0;
    
    for (NSString *itemKey in itemKeys) {
        switch(*structTypes) {
            #define JP_STRUCT_DICT_CASE(_typeName, _type)   \
            case _typeName: { \
                size_t size = sizeof(_type); \
                _type *val = malloc(size);   \
                memcpy(val, structData + position, size);   \
                [dict setObject:@(*val) forKey:itemKey];    \
                free(val);  \
                position += size;   \
                break;  \
            }
            JP_STRUCT_DICT_CASE('c', char)
            JP_STRUCT_DICT_CASE('C', unsigned char)
            JP_STRUCT_DICT_CASE('s', short)
            JP_STRUCT_DICT_CASE('S', unsigned short)
            JP_STRUCT_DICT_CASE('i', int)
            JP_STRUCT_DICT_CASE('I', unsigned int)
            JP_STRUCT_DICT_CASE('l', long)
            JP_STRUCT_DICT_CASE('L', unsigned long)
            JP_STRUCT_DICT_CASE('q', long long)
            JP_STRUCT_DICT_CASE('Q', unsigned long long)
            JP_STRUCT_DICT_CASE('f', float)
            JP_STRUCT_DICT_CASE('F', CGFloat)
            JP_STRUCT_DICT_CASE('N', NSInteger)
            JP_STRUCT_DICT_CASE('U', NSUInteger)
            JP_STRUCT_DICT_CASE('d', double)
            JP_STRUCT_DICT_CASE('B', BOOL)
            
            case '*':
            case '^': {
                size_t size = sizeof(void *);
                void *val = malloc(size);
                memcpy(val, structData + position, size);
                [dict setObject:[JPBoxing boxPointer:val] forKey:itemKey];
                position += size;
                break;
            }
            case '{': {
                NSString *subStructName = [NSString stringWithCString:structTypes encoding:NSASCIIStringEncoding];
                NSUInteger end = [subStructName rangeOfString:@"}"].location;
                if (end != NSNotFound) {
                    subStructName = [subStructName substringWithRange:NSMakeRange(1, end - 1)];
                    NSDictionary *subStructDefine = [JPExtension registeredStruct][subStructName];
                    int size = sizeOfStructTypes(subStructDefine[@"types"]);
                    NSDictionary *subDict = getDictOfStruct(structData + position, subStructDefine);
                    [dict setObject:subDict forKey:itemKey];
                    position += size;
                    structTypes += end;
                    break;
                }
            }
        }
        structTypes ++;
    }
    return dict;
}

static NSString *extractStructName(NSString *typeEncodeString)
{
    NSArray *array = [typeEncodeString componentsSeparatedByString:@"="];
    NSString *typeString = array[0];
    int firstValidIndex = 0;
    for (int i = 0; i< typeString.length; i++) {
        char c = [typeString characterAtIndex:i];
        if (c == '{' || c=='_') {
            firstValidIndex++;
        }else {
            break;
        }
    }
    return [typeString substringFromIndex:firstValidIndex];
}

#pragma mark - Utils

// 去掉 string 两端的空字符串
static NSString *trim(NSString *string)
{
    return [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static BOOL blockTypeIsObject(NSString *typeString)
{
    return [typeString rangeOfString:@"*"].location != NSNotFound || [typeString isEqualToString:@"id"];
}

static BOOL blockTypeIsScalarPointer(NSString *typeString)
{
    NSUInteger location = [typeString rangeOfString:@"*"].location;
    NSString *typeWithoutAsterisk = trim([typeString stringByReplacingOccurrencesOfString:@"*" withString:@""]);
    
    return (location == typeString.length-1 &&
            !NSClassFromString(typeWithoutAsterisk));
}

// 获取真正的方法名
static NSString *convertJPSelectorString(NSString *selectorString)
{
    // 用 - 代替 __
    NSString *tmpJSMethodName = [selectorString stringByReplacingOccurrencesOfString:@"__" withString:@"-"];
    // 用 ： 代替 _
    NSString *selectorName = [tmpJSMethodName stringByReplacingOccurrencesOfString:@"_" withString:@":"];
    // 用 _ 代替 -
    return [selectorName stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
}

#pragma mark - Object format

// oc 转成 js
static id formatOCToJS(id obj)
{
    if ([obj isKindOfClass:[NSString class]] || [obj isKindOfClass:[NSDictionary class]] || [obj isKindOfClass:[NSArray class]] || [obj isKindOfClass:[NSDate class]]) {
        return _autoConvert ? obj: _wrapObj([JPBoxing boxObj:obj]);
    }
    if ([obj isKindOfClass:[NSNumber class]]) {
        return _convertOCNumberToString ? [(NSNumber*)obj stringValue] : obj;
    }
    if ([obj isKindOfClass:NSClassFromString(@"NSBlock")] || [obj isKindOfClass:[JSValue class]]) {
        return obj;
    }
    return _wrapObj(obj);
}

// js 转成 oc
static id formatJSToOC(JSValue *jsval)
{
    // 将 JSValue 转成 OC 对象
    id obj = [jsval toObject];
    // obj 为 nil 或者是 NSNull，返回一个 NSObject 对象
    if (!obj || [obj isKindOfClass:[NSNull class]]) return _nilObj;
    
    // obj 是 JPBoxing 实例对象，解包返回真实内容
    if ([obj isKindOfClass:[JPBoxing class]]) return [obj unbox];
    // obj 是数组对象
    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *newArr = [[NSMutableArray alloc] init];
        for (int i = 0; i < [(NSArray*)obj count]; i ++) {
            [newArr addObject:formatJSToOC(jsval[i])];
        }
        return newArr;
    }
    // obj 是字典对象
    if ([obj isKindOfClass:[NSDictionary class]]) {
        if (obj[@"__obj"]) {
            id ocObj = [obj objectForKey:@"__obj"];
            if ([ocObj isKindOfClass:[JPBoxing class]]) return [ocObj unbox];
            return ocObj;
        } else if (obj[@"__clsName"]) {
            // 如果存在 __clsName 对象，那么把 clsName 对应的 Class 拿出
            return NSClassFromString(obj[@"__clsName"]);
        }
        // 如果是 block
        if (obj[@"__isBlock"]) {
            Class JPBlockClass = NSClassFromString(@"JPBlock");
            if (JPBlockClass && ![jsval[@"blockObj"] isUndefined]) {
                // 此处是 JPBlock 拓展
                return [JPBlockClass performSelector:@selector(blockWithBlockObj:) withObject:[jsval[@"blockObj"] toObject]];
            } else {
                // 生成 block
                return genCallbackBlock(jsval);
            }
        }
        NSMutableDictionary *newDict = [[NSMutableDictionary alloc] init];
        for (NSString *key in [obj allKeys]) {
            [newDict setObject:formatJSToOC(jsval[key]) forKey:key];
        }
        return newDict;
    }
    return obj;
}

static id _formatOCToJSList(NSArray *list)
{
    NSMutableArray *arr = [NSMutableArray new];
    for (id obj in list) {
        [arr addObject:formatOCToJS(obj)];
    }
    return arr;
}

// 把 oc 对象转为 js 对象 （增加了 __obj __clsName 等字段）
static NSDictionary *_wrapObj(id obj)
{
    if (!obj || obj == _nilObj) {
        return @{@"__isNil": @(YES)};
    }
    return @{@"__obj": obj, @"__clsName": NSStringFromClass([obj isKindOfClass:[JPBoxing class]] ? [[((JPBoxing *)obj) unbox] class]: [obj class])};
}

// 对 oc 对象解包 转为 js
static id _unboxOCObjectToJS(id obj)
{
    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *newArr = [[NSMutableArray alloc] init];
        for (int i = 0; i < [(NSArray*)obj count]; i ++) {
            [newArr addObject:_unboxOCObjectToJS(obj[i])];
        }
        return newArr;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *newDict = [[NSMutableDictionary alloc] init];
        for (NSString *key in [obj allKeys]) {
            [newDict setObject:_unboxOCObjectToJS(obj[key]) forKey:key];
        }
        return newDict;
    }
    if ([obj isKindOfClass:[NSString class]] ||[obj isKindOfClass:[NSNumber class]] || [obj isKindOfClass:NSClassFromString(@"NSBlock")] || [obj isKindOfClass:[NSDate class]]) {
        return obj;
    }
    return _wrapObj(obj);
}
#pragma clang diagnostic pop
@end


@implementation JPExtension

+ (void)main:(JSContext *)context{}

+ (void *)formatPointerJSToOC:(JSValue *)val
{
    id obj = [val toObject];
    if ([obj isKindOfClass:[NSDictionary class]]) {
        if (obj[@"__obj"] && [obj[@"__obj"] isKindOfClass:[JPBoxing class]]) {
            return [(JPBoxing *)(obj[@"__obj"]) unboxPointer];
        } else {
            return NULL;
        }
    } else if (![val toBool]) {
        return NULL;
    } else{
        return [((JPBoxing *)[val toObject]) unboxPointer];
    }
}

+ (id)formatRetainedCFTypeOCToJS:(CFTypeRef)CF_CONSUMED type
{
    return formatOCToJS([JPBoxing boxPointer:(void *)type]);
}

+ (id)formatPointerOCToJS:(void *)pointer
{
    return formatOCToJS([JPBoxing boxPointer:pointer]);
}

+ (id)formatJSToOC:(JSValue *)val
{
    if (![val toBool]) {
        return nil;
    }
    return formatJSToOC(val);
}

+ (id)formatOCToJS:(id)obj
{
    JSContext *context = [JSContext currentContext] ? [JSContext currentContext]: _context;
    return [context[@"_formatOCToJS"] callWithArguments:@[formatOCToJS(obj)]];
}

+ (int)sizeOfStructTypes:(NSString *)structTypes
{
    return sizeOfStructTypes(structTypes);
}

+ (void)getStructDataWidthDict:(void *)structData dict:(NSDictionary *)dict structDefine:(NSDictionary *)structDefine
{
    return getStructDataWithDict(structData, dict, structDefine);
}

+ (NSDictionary *)getDictOfStruct:(void *)structData structDefine:(NSDictionary *)structDefine
{
    return getDictOfStruct(structData, structDefine);
}

+ (NSMutableDictionary *)registeredStruct
{
    return _registeredStruct;
}

+ (NSDictionary *)overideMethods
{
    return _JSOverideMethods;
}

+ (NSMutableSet *)includedScriptPaths
{
    return _runnedScript;
}

@end
