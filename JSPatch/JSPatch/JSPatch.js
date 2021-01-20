var global = this

// 执行此js会立即执行此函数
;(function() {

  var _ocCls = {};
  var _jsCls = {};

  // 将 oc 对象 转为 js 类型
  var _formatOCToJS = function(obj) {
    // 如果 oc 端返回的直接是 undefined 或者 null，那么直接返回 false
    if (obj === undefined || obj === null) return false
    if (typeof obj == "object") {
      // js 传给 oc 时会把自己包裹在 __obj 中。因此，存在 __obj 就可以直接拿到 js 对象
      if (obj.__obj) return obj
      // 如果是空，那么直接返回 false。因为如果返回 null 的话，就无法调用方法了
      if (obj.__isNil) return false
    }
    if (obj instanceof Array) {
      // 如果是数组，要对每一个 oc 转 js 一下
      var ret = []
      obj.forEach(function(o) {
        ret.push(_formatOCToJS(o))
      })
      return ret
    }
    if (obj instanceof Function) {
        return function() {
            // 如果 oc 传给 js 的是一个函数，那么 js 端调用的时候就需要先把 js 参数转为 oc 对象，调用
            var args = Array.prototype.slice.call(arguments)
            var formatedArgs = _OC_formatJSToOC(args)
            for (var i = 0; i < args.length; i++) {
                if (args[i] === null || args[i] === undefined || args[i] === false) {
                    // splice：通过删除或替换现有元素或者原地添加新的元素来修改数组,并以数组形式返回被修改的内容
                    // 将第 i 个参数 替换为 undefined
                    formatedArgs.splice(i, 1, undefined)
                } else if (args[i] == nsnull) {
                    // 将第 i 个参数 替换为 null
                    formatedArgs.splice(i, 1, null)
                }
           }
        // 在调用完 oc 方法后，又要 oc 对象转为 js 对象回传给 oc
        return _OC_formatOCToJS(obj.apply(obj, formatedArgs))
      }
    }
    if (obj instanceof Object) {
      // 如果是一个 object 并且没有 __obj，那么把所有的 key 都 format 一遍
      var ret = {}
      for (var key in obj) {
        ret[key] = _formatOCToJS(obj[key])
      }
      return ret
    }
    return obj
  }
  
  // 执行 js 方法, 返回 js 对象
  // 把要调用的实例对象、类名、方法名、参数、是否是父类、是否是可调用方法形式，参数传递给 oc
  var _methodFunc = function(instance, clsName, methodName, args, isSuper, isPerformSelector) {
    var selectorName = methodName
    // 从 xxx_xxx 变为了 xxx:xxx:
    // js 端的方法都是 xxx_xxx 的形式，而 oc 端的方法已经在 defineClass 的时候转为了 xxx:xxx: 的形式。所以一般情况下 js 调用 oc 方法的时候都需要先把方法名转换一下。也就是当 isPerformSelector 为 false 的情况。
    // 那么什么时候这个属性为 true 呢？当 js 端调用 performSelector 这个的方法的时候。这个方法默认需要传入 xxx:xxx: 形式的 OC selector 名。
    // 一般 performSelector 用于从 oc 端动态传来 selectorName 需要 js 执行的时候。没有太多的使用场景
    if (!isPerformSelector) {
      methodName = methodName.replace(/__/g, "-")
      selectorName = methodName.replace(/_/g, ":").replace(/-/g, "_")
      var marchArr = selectorName.match(/:/g)
      var numOfArgs = marchArr ? marchArr.length : 0
      if (args.length > numOfArgs) {
        selectorName += ":"
      }
    }
    // 是否是类方法来决定调用 _OC_callI 还是 _OC_callC
    var ret = instance ? _OC_callI(instance, selectorName, args, isSuper):
                         _OC_callC(clsName, selectorName, args)
    return _formatOCToJS(ret)
  }

  // 创建一个存放自定义方法的字典
  var _customMethods = {
    // 调用 native 相应的方法
    __c: function(methodName) {
      var slf = this

      // 如果 oc 返回了一个空对象，在 js 端会以 false 的形式接受。当这个空对象再调用方法的时候，就会走到这个分支中，直接返回 false，而不会走 oc 的消息转发
      if (slf instanceof Boolean) {
        return function() {
          return false
        }
      }
      if (slf[methodName]) {
        return slf[methodName].bind(slf);
      }

      // 抛出异常
      if (!slf.__obj && !slf.__clsName) {
        throw new Error(slf + '.' + methodName + ' is undefined')
      }
      // 如果当前调用的父类的方法，那么通过 OC 方法获取该 clsName 的父类的名字
      if (slf.__isSuper && slf.__clsName) {
          slf.__clsName = _OC_superClsName(slf.__obj.__realClsName ? slf.__obj.__realClsName: slf.__clsName);
      }
      var clsName = slf.__clsName
      if (clsName && _ocCls[clsName]) {
        // 根据 __obj 字段判断是否是实例方法或者类方法
        var methodType = slf.__obj ? 'instMethods': 'clsMethods'
        // 如果当前方法是提前定义的方法，那么直接走定义方法的调用
        if (_ocCls[clsName][methodType][methodName]) {
          slf.__isSuper = 0;
          return _ocCls[clsName][methodType][methodName].bind(slf)
        }
      }

      // 当前方法不是在 js 中定义的，那么直接调用 oc 的方法
      return function(){
        var args = Array.prototype.slice.call(arguments)
        return _methodFunc(slf.__obj, slf.__clsName, methodName, args, slf.__isSuper)
      }
    },

    super: function() {
      var slf = this
      if (slf.__obj) {
        slf.__obj.__realClsName = slf.__realClsName;
      }
      return {__obj: slf.__obj, __clsName: slf.__clsName, __isSuper: 1}
    },

    performSelectorInOC: function() {
      var slf = this
      var args = Array.prototype.slice.call(arguments)
      return {__isPerformInOC:1, obj:slf.__obj, clsName:slf.__clsName, sel: args[0], args: args[1], cb: args[2]}
    },

    performSelector: function() {
      var slf = this
      var args = Array.prototype.slice.call(arguments)
      return _methodFunc(slf.__obj, slf.__clsName, args[0], args.splice(1), slf.__isSuper, true)
    }
  }

  for (var method in _customMethods) {
    // hasOwnProperty() 方法会返回一个布尔值，指示对象自身属性中是否具有指定的属性（也就是，是否有指定的键）
    if (_customMethods.hasOwnProperty(method)) {
      // Object.defineProperty()：直接在一个对象上定义一个新属性，或者修改一个对象的现有属性，并返回此对象。
      // Object.defineProperty(obj, prop, descriptor)
      // obj：要定义属性的对象
      // prop：要定义或修改的属性的名称或 Symbol
      // descriptor：要定义或修改的属性描述符
      // value：该属性对应的值。可以是任何有效的 JavaScript 值（数值，对象，函数等）
      // configurable：当且仅当该属性的 configurable 键值为 true 时，该属性的描述符才能够被改变，同时该属性也能从对应的对象上被删除
      // enumerable：当且仅当该属性的 enumerable 键值为 true 时，该属性才会出现在对象的枚举属性中
      Object.defineProperty(Object.prototype, method, {value: _customMethods[method], configurable:false, enumerable: false})
    }
  }

  // 在JS全局作用域上创建一个同名变量，变量指向一个字典，字典属性 __clsName 保存类名
  // 执行require('UIView') ：在全局作用域生成了 UIView 变量，指向一个对象：{ __clsName: "UIView" }
  var _require = function(clsName) {
    // 判断全局对象是否已经存在
    if (!global[clsName]) {
      // 创建全局对象
      global[clsName] = {
        __clsName: clsName
      }
    }
    // 返回创建的对象
    return global[clsName]
  }

  // 全局创建对象的方法，直接为 require 的类创建一个它的对象
  global.require = function() {
    var lastRequire
    // 根据函数参数个数进行遍历
    for (var i = 0; i < arguments.length; i ++) {
      // 使用逗号，将字符串分割成字符串数组
      arguments[i].split(',').forEach(function(clsName) {
        // 使用 trim 方法，将 clsName 两端空白字符删除，调用 _require 方法获取创建的对象
        // lastRequire：例如 { __clsName: "UIAlertView" }
        lastRequire = _require(clsName.trim())
      })
    }
    return lastRequire
  }

  // 对 js 端定义的 method 进行预处理，取出方法的参数个数。hook 方法，预处理方法的参数，将其转为 js 对象
  var _formatDefineMethods = function(methods, newMethods, realClsName) {
    for (var methodName in methods) {
      // value 不是 function 类型 则return
      if (!(methods[methodName] instanceof Function)) return;
      // IIFE 立即调用{}中的内容
      (function(){
        // originMethod 指向一个 Function 方法
        var originMethod = methods[methodName]
        // methodName 对应的 value 变成一个数组，保存到 newMethods 新方法列表字典中
        // 数组第一个参数：originMethod 方法参数个数
        // 数组第一个参数：一个匿名函数
        // 因为runtime 添加方法的时候需要设置函数签名，因此需要知道方法中参数个数。这里直接在 js 中将参数个数取出
        newMethods[methodName] = [originMethod.length, function() {
          try {
            // Array.prototype.slice.call()，将一个类数组（Array-like）对象/集合转换成一个新数组
            // arguments 是一个对应于传递给函数的参数的类数组对象
            // js 端执行的方法，需要先把参数转为 js 的类型
            var args = _formatOCToJS(Array.prototype.slice.call(arguments))
            // 暂存之前的 self 对象
            var lastSelf = global.self
            // oc 调用 js 方法的时候，默认第一个参数是 self
            global.self = args[0]
            if (global.self) global.self.__realClsName = realClsName
            // oc 调用 js 方法的时候，第一个参数是 self，因此要把它去掉
            args.splice(0,1)
            // 调用 js 方法
            // apply() 方法调用一个具有给定this值的函数，以及作为一个数组（或类似数组对象）提供的参数
            // originMethod：在 originMethod 函数运行时使用的 this 值
            // args：作为单独的参数传给 originMethod 函数
            var ret = originMethod.apply(originMethod, args)
            // 恢复 原始的 self 指向
            global.self = lastSelf
            return ret
          } catch(e) {
            _OC_catch(e.message, e.stack)
          }
        }]
      })()
    }
  }

  // 替换 this 为 self
  var _wrapLocalMethod = function(methodName, func, realClsName) {
    return function() {
      var lastSelf = global.self
      global.self = this
      this.__realClsName = realClsName
      var ret = func.apply(this, arguments)
      global.self = lastSelf
      return ret
    }
  }

  // 保存js新增的某个类的方法到 _ocCls 中
  var _setupJSMethod = function(className, methods, isInst, realClsName) {
    for (var name in methods) {
      var key = isInst ? 'instMethods': 'clsMethods',
          func = methods[name]
      _ocCls[className][key][name] = _wrapLocalMethod(name, func, realClsName)
    }
  }

  // 返回属性的 get 方法
  var _propertiesGetFun = function(name){
    return function(){
      var slf = this;
      if (!slf.__ocProps) {
        // 获取 oc 的关联属性：属性列表
        var props = _OC_getCustomProps(slf.__obj)
        // 属性列表 不存在
        if (!props) {
          // 初始化一个空字典
          props = {}
          // 调用 oc _OC_setCustomProps 方法，给对象设置自定义属性
          _OC_setCustomProps(slf.__obj, props)
        }
        // 将 oc 的关联属性（属性列表）赋给 js 端对象的 __ocProps
        slf.__ocProps = props;
      }
      // 从属性列表中，根据属性名称，取出对应属性值
      return slf.__ocProps[name];
    };
  }

  // 返回属性的 set 方法
  var _propertiesSetFun = function(name){
    return function(jval){
      var slf = this;
      // 判断 js 的 _ocProps 是否存在
      if (!slf.__ocProps) {
        // 获取 oc 的关联属性：属性列表
        var props = _OC_getCustomProps(slf.__obj)
        // 属性列表 不存在
        if (!props) {
          // 初始化空字典
          props = {}
          // 设置 oc 的关联属性：一个空的属性列表
          _OC_setCustomProps(slf.__obj, props)
        }
        slf.__ocProps = props;
      }
      // 根据 name 给属性列表中 某个 name 属性赋值
      // 由于 __ocProps 、props 和 oc 的关联属性，指向的地址相同，所以对于 property 的修改 只需直接修改 js 端 __ocProps 属性就行
      slf.__ocProps[name] = jval;
    };
  }
    
  // 会在 oc 中生成对应的类
  // declaration：类名，父类，协议的描述，cls:supercls<protoclo..>
  // properties：属性数组
  // instMethods：实例方法列表
  // clsMethods：类方法列表
  global.defineClass = function(declaration, properties, instMethods, clsMethods) {
    console.log(declaration +'\n' + JSON.stringify(properties) +'\n' + JSON.stringify(instMethods) +'\n' + JSON.stringify(clsMethods))
    var newInstMethods = {}, newClsMethods = {}
    // 可变参数，需要判断properties是否是数组类型，如果不是，说明使用者没有设置properties
    if (!(properties instanceof Array)) {
      clsMethods = instMethods
      instMethods = properties
      properties = null
    }

    // 如果存在properties，在实例方法列表中增加对应的 get set 方法
    if (properties) {
      properties.forEach(function(name){
        // 实例方法列表中，如果不包含对应 get 方法
        if (!instMethods[name]) {
          // 将 get 方法设置到实例方法列表中，instMethods： [方法名称：function(){}，方法名称：function(){}，..]
          instMethods[name] = _propertiesGetFun(name);
        }
        // 对应 set 方法名称
        var nameOfSet = "set"+ name.substr(0,1).toUpperCase() + name.substr(1);
        // 实例方法列表，如果不包含对应 set 方法
        if (!instMethods[nameOfSet]) {
            // 将 set 方法设置到实例方法列表中
          instMethods[nameOfSet] = _propertiesSetFun(name);
        }
      });
    }

    // 从 declaration 中直接截取类名 例：
    // declaration：JPTableViewController : UITableViewController <UIAlertViewDelegate>
    // realClsName：JPTableViewController
    var realClsName = declaration.split(':')[0].trim()

    // 预处理要定义的方法，对方法进行切片，处理参数
    _formatDefineMethods(instMethods, newInstMethods, realClsName)
    _formatDefineMethods(clsMethods, newClsMethods, realClsName)

    // 在 OC 中定义这个类，返回的值类型为 {cls: xxx, superCls: xxx}
    var ret = _OC_defineClass(declaration, newInstMethods, newClsMethods)
    // className 是从 OC 中截取的 cls 的名字。本质上和 realClsName 是一致的
    var className = ret['cls']
    var superCls = ret['superCls']

    // 初始化该类的类方法和实例方法到 _ocCls 中
    _ocCls[className] = {
      instMethods: {},
      clsMethods: {},
    }

    // 如果父类被 defineClass 过，那么要先把父类的方法扔到子类中去。子类调用父类中实现的方法的时候，直接调用
    if (superCls.length && _ocCls[superCls]) {
      for (var funcName in _ocCls[superCls]['instMethods']) {
        _ocCls[className]['instMethods'][funcName] = _ocCls[superCls]['instMethods'][funcName]
      }
      for (var funcName in _ocCls[superCls]['clsMethods']) {
        _ocCls[className]['clsMethods'][funcName] = _ocCls[superCls]['clsMethods'][funcName]
      }
    }

    // 把js增加的方法存到 _ocCls 对应的类中。和 _formatDefineMethods 的差别在于这个方法不需要把参数个数提取出来
    _setupJSMethod(className, instMethods, 1, realClsName)
    _setupJSMethod(className, clsMethods, 0, realClsName)

    // 返回了一个 require() 方法产生的对象
    return require(className)
  }

  // 定义协议
  // 协议名称，实例协议方法，类协议方法
  global.defineProtocol = function(declaration, instProtos , clsProtos) {
      var ret = _OC_defineProtocol(declaration, instProtos,clsProtos);
      return ret
  }

  // 返回一个对象,在对象中提供了一个标识 __isBlock
  global.block = function(args, cb) {
    var that = this
    var slf = global.self
    if (args instanceof Function) {
      cb = args
      args = ''
    }
    var callback = function() {
      var args = Array.prototype.slice.call(arguments)
      global.self = slf
      return cb.apply(that, _formatOCToJS(args))
    }
    var ret = {args: args, cb: callback, argCount: cb.length, __isBlock: 1}
    if (global.__genBlock) {
      ret['blockObj'] = global.__genBlock(args, cb)
    }
    return ret
  }
  
  if (global.console) {
    var jsLogger = console.log;
    global.console.log = function() {
      global._OC_log.apply(global, arguments);
      if (jsLogger) {
        jsLogger.apply(global.console, arguments);
      }
    }
  } else {
    global.console = {
      log: global._OC_log
    }
  }

  // 一些不需要继承 OC，和 OC 没有联系，如数据层的 dataSource/manager，直接使用 JS 原生类， 减少转化为 OC 类时的性能损耗
  // declaration：描述
  // instMethods：实例方法列表
  // clsMethods：类方法列表
  global.defineJSClass = function(declaration, instMethods, clsMethods) {
    var o = function() {},
        // 以 : 进行分割
        a = declaration.split(':'),
        // 类名
        clsName = a[0].trim(),
        // 父类名
        superClsName = a[1] ? a[1].trim() : null
    o.prototype = {
      init: function() {
        if (this.super()) this.super().init()
        return this;
      },
      super: function() {
        return superClsName ? _jsCls[superClsName].prototype : null
      }
    }
    var cls = {
      alloc: function() {
        return new o;
      }
    }
    for (var methodName in instMethods) {
      o.prototype[methodName] = instMethods[methodName];
    }
    for (var methodName in clsMethods) {
      cls[methodName] = clsMethods[methodName];
    }
    global[clsName] = cls
    _jsCls[clsName] = o
  }
  
  // JSContext 全局对象增加的属性
  global.YES = 1
  global.NO = 0
  global.nsnull = _OC_null
  global._formatOCToJS = _formatOCToJS
  
})()
