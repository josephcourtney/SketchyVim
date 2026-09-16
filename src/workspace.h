#pragma once
#include <Cocoa/Cocoa.h>
#include "event_tap.h"

extern char* string_copy(char* s);

@interface workspace_context : NSObject {
}
- (id)init;
@end

void workspace_begin(void **context);
