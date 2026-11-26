#import "IVLLyricCell.h"
#import "IVLExtras.h"

#pragma mark - Karaoke label

@implementation IVLKaraokeLabel {
    NSTextStorage *_cachedStorage;
    NSLayoutManager *_cachedLM;
    NSTextContainer *_cachedTC;
    NSAttributedString *_cachedSource;
    CGFloat _cachedWidth;
    NSInteger _lastVisualState;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _dimColor = [UIColor colorWithWhite:1 alpha:0.35];
        _brightColor = UIColor.whiteColor;
        _lastVisualState = -1;
    }
    return self;
}

- (void)setAttributedText:(NSAttributedString *)attributedText {
    [super setAttributedText:attributedText];
    _cachedSource = nil;
    _lastVisualState = -1;
}

- (void)setWords:(NSArray<IVLWord *> *)words {
    _words = [words copy];
    _lastVisualState = -1;
    if (_karaokeActive) [self setNeedsDisplay];
}

- (NSInteger)visualStateForTime:(NSInteger)t {
    if (!_karaokeActive || !_words.count) return -2;
    NSUInteger done = 0, loc = 0;
    NSInteger fracStep = 0;
    for (IVLWord *w in _words) {
        NSUInteger len = w.text.length;
        if (t >= w.endMs) {
            done = loc + len;
        } else if (t >= w.startMs) {
            CGFloat f = (CGFloat)(t - w.startMs) / (CGFloat)MAX(1, w.endMs - w.startMs);
            fracStep = (NSInteger)(f * 64.0) + 1;
            break;
        } else {
            break;
        }
        loc += len;
    }
    return (NSInteger)((done << 8) | (fracStep & 0xFF));
}

- (void)setTimeMs:(NSInteger)timeMs {
    if (_timeMs == timeMs) return;
    _timeMs = timeMs;
    if (!_karaokeActive) return;
    NSInteger st = [self visualStateForTime:timeMs];
    if (st == _lastVisualState) return;
    _lastVisualState = st;
    [self setNeedsDisplay];
}

- (void)setKaraokeActive:(BOOL)karaokeActive {
    if (_karaokeActive == karaokeActive) return;
    _karaokeActive = karaokeActive;
    _lastVisualState = -1;
    [self setNeedsDisplay];
}

- (void)ensureTextKitForSource:(NSAttributedString *)src width:(CGFloat)width {
    if (_cachedStorage && _cachedSource == src && fabs(_cachedWidth - width) < 0.5) return;
    _cachedSource = src;
    _cachedWidth = width;
    _cachedStorage = [[NSTextStorage alloc] initWithAttributedString:src];
    _cachedLM = [NSLayoutManager new];
    _cachedTC = [[NSTextContainer alloc] initWithSize:CGSizeMake(MAX(1.0, width), CGFLOAT_MAX)];
    _cachedTC.lineFragmentPadding = 0;
    _cachedTC.lineBreakMode = NSLineBreakByWordWrapping;
    [_cachedLM addTextContainer:_cachedTC];
    [_cachedStorage addLayoutManager:_cachedLM];
}

- (void)drawTextInRect:(CGRect)rect {
    NSAttributedString *src = self.attributedText;
    if (!_karaokeActive || !_words.count || !src.length) { [super drawTextInRect:rect]; return; }

    [self ensureTextKitForSource:src width:rect.size.width];
    NSTextStorage *storage = _cachedStorage;
    NSLayoutManager *lm = _cachedLM;
    NSTextContainer *tc = _cachedTC;

    NSRange all = NSMakeRange(0, storage.length);
    [storage addAttribute:NSForegroundColorAttributeName value:_dimColor range:all];

    NSRange glyphs = [lm glyphRangeForTextContainer:tc];
    CGRect used = [lm usedRectForTextContainer:tc];
    CGPoint origin = CGPointMake(rect.origin.x, rect.origin.y + MAX(0, (rect.size.height - used.size.height) / 2.0));
    [lm drawGlyphsForGlyphRange:glyphs atPoint:origin];

    // Progress through the words
    NSInteger t = _timeMs;
    NSUInteger done = 0, loc = 0;
    NSRange partial = NSMakeRange(NSNotFound, 0);
    CGFloat frac = 0;
    for (IVLWord *w in _words) {
        if (loc >= storage.length) break;
        NSUInteger len = MIN(w.text.length, storage.length - loc);
        if (t >= w.endMs) {
            done = loc + len;
        } else if (t >= w.startMs) {
            partial = NSMakeRange(loc, len);
            frac = (CGFloat)(t - w.startMs) / (CGFloat)MAX(1, w.endMs - w.startMs);
            break;
        } else break;
        loc += len;
    }
    if (done == 0 && partial.location == NSNotFound) return;

    UIBezierPath *clip = [UIBezierPath bezierPath];
    [lm enumerateLineFragmentsForGlyphRange:glyphs usingBlock:^(CGRect r, CGRect usedR, NSTextContainer *c, NSRange gr, BOOL *stop) {
        NSRange cr = [lm characterRangeForGlyphRange:gr actualGlyphRange:NULL];
        CGFloat minX = usedR.origin.x, maxX = minX;
        if (NSMaxRange(cr) <= done) {
            maxX = CGRectGetMaxX(usedR);
        } else {
            if (done > cr.location) {
                NSRange dg = [lm glyphRangeForCharacterRange:NSMakeRange(cr.location, done - cr.location) actualCharacterRange:NULL];
                maxX = CGRectGetMaxX([lm boundingRectForGlyphRange:dg inTextContainer:tc]);
            }
            if (partial.location != NSNotFound) {
                NSRange inter = NSIntersectionRange(partial, cr);
                if (inter.length) {
                    NSRange pg = [lm glyphRangeForCharacterRange:inter actualCharacterRange:NULL];
                    CGRect b = [lm boundingRectForGlyphRange:pg inTextContainer:tc];
                    maxX = MAX(maxX, b.origin.x + b.size.width * frac);
                }
            }
        }
        if (maxX > minX) {
            [clip appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(origin.x + minX, origin.y + r.origin.y - 4, maxX - minX, r.size.height + 8)]];
        }
    }];

    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSaveGState(ctx);
    [clip addClip];
    [storage addAttribute:NSForegroundColorAttributeName value:_brightColor range:all];
    [lm drawGlyphsForGlyphRange:glyphs atPoint:origin];
    CGContextRestoreGState(ctx);
}

@end

#pragma mark - Cell

@interface IVLLyricCell ()
@property (nonatomic, strong, readwrite) IVLLyricLine *line;
@end

@implementation IVLLyricCell {
    UIStackView *_stack;
    IVLKaraokeLabel *_label;
    UILabel *_pron;
    UILabel *_trans;
    UIStackView *_dots;
    IVLCellStyle _style;
    BOOL _active;
    NSLayoutConstraint *_leading, *_trailing;
}

+ (NSString *)reuseID { return @"IVLLyricCell"; }

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = UIColor.clearColor;
        self.contentView.backgroundColor = UIColor.clearColor;
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _label = [IVLKaraokeLabel new];
        _label.numberOfLines = 0;
        _label.textColor = UIColor.whiteColor;

        _pron = [UILabel new];
        _pron.numberOfLines = 0;
        _pron.textColor = [UIColor colorWithWhite:1 alpha:0.7];

        _trans = [UILabel new];
        _trans.numberOfLines = 0;
        _trans.textColor = [UIColor colorWithWhite:1 alpha:0.8];

        _dots = [UIStackView new];
        _dots.axis = UILayoutConstraintAxisHorizontal;
        _dots.spacing = 8;
        for (int i = 0; i < 3; i++) {
            UIView *d = [UIView new];
            d.backgroundColor = UIColor.whiteColor;
            d.layer.cornerRadius = 5;
            d.alpha = 0.3;
            [d.widthAnchor constraintEqualToConstant:10].active = YES;
            [d.heightAnchor constraintEqualToConstant:10].active = YES;
            [_dots addArrangedSubview:d];
        }

        _stack = [[UIStackView alloc] initWithArrangedSubviews:@[_label, _pron, _trans, _dots]];
        _stack.axis = UILayoutConstraintAxisVertical;
        _stack.spacing = 4;
        _stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_stack];

        _leading = [_stack.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:28];
        _trailing = [_stack.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-28];
        NSLayoutConstraint *bottom = [_stack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12];
        bottom.priority = UILayoutPriorityDefaultHigh + 10;
        [NSLayoutConstraint activateConstraints:@[
            _leading, _trailing,
            [_stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],
            bottom,
        ]];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [_dots.layer removeAllAnimations];
    _label.karaokeActive = NO;
    _label.words = nil;
}

- (void)configureWithLine:(IVLLyricLine *)line style:(IVLCellStyle)style active:(BOOL)active past:(BOOL)past {
    self.line = line;
    _style = style;

    NSTextAlignment align = style.alignment;
    if (line.alternateVoice && align == NSTextAlignmentLeft) align = NSTextAlignmentRight;
    UIStackViewAlignment stackAlign = align == NSTextAlignmentCenter ? UIStackViewAlignmentCenter
                                    : (align == NSTextAlignmentRight ? UIStackViewAlignmentTrailing : UIStackViewAlignmentLeading);

    if (line.instrumental) {
        _label.hidden = YES; _pron.hidden = YES; _trans.hidden = YES;
        _dots.hidden = NO;
        _stack.alignment = stackAlign;
        self.accessibilityLabel = @"♪";
    } else {
        _dots.hidden = YES;
        _label.hidden = NO;
        _stack.alignment = UIStackViewAlignmentFill;

        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
        ps.alignment = align;
        ps.lineBreakMode = NSLineBreakByWordWrapping;
        ps.lineSpacing = 2;
        UIFont *font = [UIFont systemFontOfSize:style.fontSize weight:UIFontWeightBold];
        _label.attributedText = [[NSAttributedString alloc] initWithString:line.text ?: @""
                                                                attributes:@{ NSFontAttributeName: font, NSParagraphStyleAttributeName: ps,
                                                                              NSForegroundColorAttributeName: UIColor.whiteColor }];
        _label.words = (style.karaoke && style.synced) ? line.words : nil;

        _pron.hidden = line.pronunciation.length == 0;
        _pron.text = line.pronunciation;
        _pron.font = [UIFont systemFontOfSize:MAX(12, style.fontSize * 0.55) weight:UIFontWeightMedium];
        _pron.textAlignment = align;

        _trans.hidden = line.translation.length == 0;
        _trans.text = line.translation;
        _trans.font = [UIFont systemFontOfSize:MAX(13, style.fontSize * 0.62) weight:UIFontWeightSemibold];
        _trans.textAlignment = align;

        NSMutableArray *ax = [NSMutableArray arrayWithObject:line.text ?: @""];
        if (line.pronunciation.length) [ax addObject:line.pronunciation];
        if (line.translation.length) [ax addObject:line.translation];
        self.accessibilityLabel = [ax componentsJoinedByString:@", "];
    }
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = style.synced ? UIAccessibilityTraitButton : UIAccessibilityTraitStaticText;
    _active = !active;   // force refresh
    [self setActive:active past:past animated:NO];
}

- (void)setActive:(BOOL)active past:(BOOL)past animated:(BOOL)animated {
    if (_active == active) return;
    _active = active;
    CGFloat alpha = !_style.synced ? 0.95 : (active ? 1.0 : 0.38);
    if (_line.instrumental && !active) alpha = 0.25;

    BOOL karaoke = active && _label.words.count > 0;
    UIColor *accent = [IVLTheme accentColor];
    _label.brightColor = accent;
    if (_label.attributedText.length) {
        NSMutableAttributedString *as = [_label.attributedText mutableCopy];
        [as addAttribute:NSForegroundColorAttributeName value:(active && _style.synced) ? accent : UIColor.whiteColor range:NSMakeRange(0, as.length)];
        _label.attributedText = as;
    }
    _label.karaokeActive = karaoke;
    _label.layer.shadowColor = accent.CGColor;
    _label.layer.shadowRadius = 10;
    _label.layer.shadowOffset = CGSizeZero;
    _label.layer.shadowOpacity = (active && !karaoke && _style.synced) ? 0.35 : 0;

    void (^changes)(void) = ^{
        self.contentView.alpha = alpha;
        CGFloat s = (active || !self->_style.synced) ? 1.0 : 0.97;
        self->_stack.transform = CGAffineTransformMakeScale(s, s);
    };
    if (animated) [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:changes completion:nil];
    else changes();

    if (_line.instrumental) {
        [_dots.layer removeAllAnimations];
        if (active) {
            CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
            pulse.fromValue = @1.0; pulse.toValue = @1.15;
            pulse.duration = 1.0; pulse.autoreverses = YES; pulse.repeatCount = HUGE_VALF;
            pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            [_dots.layer addAnimation:pulse forKey:@"pulse"];
        } else {
            for (UIView *d in _dots.arrangedSubviews) d.alpha = 0.3;
        }
    }
}

- (void)updateTime:(NSInteger)ms {
    if (!_active) return;
    if (_line.instrumental) {
        CGFloat span = MAX(1, _line.endMs - _line.startMs);
        CGFloat p = MIN(1, MAX(0, (ms - _line.startMs) / span));
        NSArray *ds = _dots.arrangedSubviews;
        for (NSUInteger i = 0; i < ds.count; i++) {
            CGFloat local = MIN(1, MAX(0, p * ds.count - i));
            ((UIView *)ds[i]).alpha = 0.3 + 0.7 * local;
        }
        return;
    }
    _label.timeMs = ms;
}

@end
