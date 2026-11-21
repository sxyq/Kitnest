// Swift 设置页的传感器列表桥接。
#import "frset_barwidgets.h"

NSArray<NSString *> *FSBarSensorKeysList(void) {
    char keys[200][8];
    int n = FSBarCopySensorKeys(keys, NULL, 200);
    NSMutableArray *arr = [NSMutableArray array];
    for (int i = 0; i < n; i++) {
        NSString *k = [NSString stringWithUTF8String:keys[i]];
        if (k.length) [arr addObject:k];
    }
    return arr;
}
