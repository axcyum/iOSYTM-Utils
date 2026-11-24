#import <UIKit/UIKit.h>
#import "IVLModels.h"

NS_ASSUME_NONNULL_BEGIN

/// UILabel that can draw a word-by-word karaoke fill (TextKit two-pass drawing with clip).
@interface IVLKaraokeLabel : UILabel
@property (nonatomic, copy, nullable) NSArray<IVLWord *> *words;
@property (nonatomic, assign) NSInteger timeMs;
@property (nonatomic, assign) BOOL karaokeActive;
@property (nonatomic, strong) UIColor *dimColor;
@property (nonatomic, strong) UIColor *brightColor;
@end

typedef struct {
    CGFloat fontSize;
    NSTextAlignment alignment;
    BOOL karaoke;
    BOOL synced;
} IVLCellStyle;

@interface IVLLyricCell : UITableViewCell
+ (NSString *)reuseID;
- (void)configureWithLine:(IVLLyricLine *)line style:(IVLCellStyle)style active:(BOOL)active past:(BOOL)past;
- (void)setActive:(BOOL)active past:(BOOL)past animated:(BOOL)animated;
- (void)updateTime:(NSInteger)ms;
@property (nonatomic, strong, readonly, nullable) IVLLyricLine *line;
@end

NS_ASSUME_NONNULL_END
