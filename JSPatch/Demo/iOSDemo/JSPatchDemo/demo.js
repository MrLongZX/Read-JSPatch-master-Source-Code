// 使用defineClass,定义 OC 已存在的方法即可覆盖，方法名规则与调用规则一样
// 覆盖原生JPViewController中的handleBtn方法
defineClass('JPViewController', {
  initSubviews: function() {
      var redView = require('UIView').alloc().initWithFrame({x:20, y:200, width:100, height:100});
      redView.setBackgroundColor(require('UIColor').redColor());
      self.view().addSubview(redView);
  },
  handleBtn: function(sender) {
    var tableViewCtrl = JPTableViewController.alloc().init()
    self.navigationController().pushViewController_animated(tableViewCtrl, YES)
  }
})
// 定义一个新类，继承于UITableViewController，遵循UIAlertViewDelegate代理，新增属性：字符串类型数组，
defineClass('JPTableViewController : UITableViewController <UIAlertViewDelegate>', ['data'], {
  dataSource: function() {
    var data = self.data();
    if (data) return data;
    var data = [];
    for (var i = 0; i < 20; i ++) {
      data.push("cell from js " + i);
    }
    self.setData(data)
    return data;
  },
  numberOfSectionsInTableView: function(tableView) {
    return 1;
  },
  tableView_numberOfRowsInSection: function(tableView, section) {
    return self.dataSource().length;
  },
  tableView_cellForRowAtIndexPath: function(tableView, indexPath) {
    var cell = tableView.dequeueReusableCellWithIdentifier("cell") 
    if (!cell) {
      cell = require('UITableViewCell').alloc().initWithStyle_reuseIdentifier(0, "cell")
    }
    cell.textLabel().setText(self.dataSource()[indexPath.row()])
    return cell
  },
  tableView_heightForRowAtIndexPath: function(tableView, indexPath) {
    return 60
  },
  tableView_didSelectRowAtIndexPath: function(tableView, indexPath) {
     var alertView = require('UIAlertView').alloc().initWithTitle_message_delegate_cancelButtonTitle_otherButtonTitles("Alert",self.dataSource()[indexPath.row()], self, "OK",  null);
     alertView.show()
  },
  alertView_willDismissWithButtonIndex: function(alertView, idx) {
    console.log('click btn ' + alertView.buttonTitleAtIndex(idx).toJS())
  }
})

//// JS
//var blk = require('JPObject').genBlock();
//blk({v: "0.0.1"});//output: I'm JSPatch, version: 0.0.1
//
//// JS
//require('JPObject').request(block("NSString *, BOOL", function(ctn, succ) {
//   console.log('syl====');
//  if (succ) console.log(ctn)  //output: I'm content
//}))
//
//defineClass('JPObject', {
//  requestUrl_withCallback: function(url, callback) {
//    //例如callback需要透传到其他方法，在OC里是这样调用：[self handleCallback:callback]
//    //在这里callback已是JS函数，需要再包一层block：
//    self.handleCallback(block('id', callback));
//  }
//});
