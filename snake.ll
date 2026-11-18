; =============================================================================
;  snake.ll  -  LLVM IR 直書きスネークゲーム
; -----------------------------------------------------------------------------
;  C などから生成したものではなく、LLVM IR を手で書いています。
;
;  ビルド:  clang -O2 snake.ll -o snake
;  実行:    ./snake
;
;  操作:    WASD / 矢印キー / HJKL で移動、P か Space で一時停止、Q で終了
;  色なし:  SNAKE_ASCII=1 ./snake  (壁 ## / 胴体 [] で描く)
;  デモ:    SNAKE_DEMO=1 ./snake   (ヘビが自動で動く。Q で終了)
;
;  macOS (Darwin) 専用: struct termios のレイアウトが Darwin 前提です。
;  libc から使うのはシステムコール系 (tcgetattr/tcsetattr/read/write/usleep/
;  time/getpid) だけで、描画・乱数・数値の文字列化などはすべて IR で実装。
; =============================================================================

; ---- 盤面サイズ (定数として直接埋め込み) ----------------------------------
;   W = 30, H = 18, CAP = W*H = 540
;   セル番号 idx = y*30 + x

; ---- libc / intrinsic ------------------------------------------------------
declare i32 @tcgetattr(i32, ptr)
declare i32 @tcsetattr(i32, i32, ptr)
declare i64 @read(i32, ptr, i64)
declare i64 @write(i32, ptr, i64)
declare i32 @usleep(i32)
declare i64 @time(ptr)
declare i32 @getpid()
declare ptr @getenv(ptr)
declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
declare void @llvm.memset.p0.i64(ptr, i8, i64, i1)
declare i32 @llvm.abs.i32(i32, i1)

; ---- 端末状態 ----------------------------------------------------------------
; Darwin の struct termios は 72 バイト:
;   c_iflag@0 c_oflag@8 c_cflag@16 c_lflag@24 (各 u64), c_cc[20]@32,
;   c_ispeed@56 c_ospeed@64.  VMIN=16, VTIME=17
@orig_tio = internal global [128 x i8] zeroinitializer, align 8
@raw_tio  = internal global [128 x i8] zeroinitializer, align 8

; ---- 出力バッファ (1 フレームをまとめて write する) ------------------------
@scr      = internal global [65536 x i8] zeroinitializer, align 16
@scr_len  = internal global i64 0
@last_kind = internal global i32 -1
@numbuf   = internal global [32 x i8] zeroinitializer
@inbuf    = internal global [32 x i8] zeroinitializer

; ---- ゲーム状態 --------------------------------------------------------------
@sx     = internal global [540 x i32] zeroinitializer   ; 胴体 x (リングバッファ)
@sy     = internal global [540 x i32] zeroinitializer   ; 胴体 y
@grid   = internal global [540 x i8]  zeroinitializer   ; 占有マップ
@head   = internal global i32 0
@len    = internal global i32 0
@dir    = internal global i32 1        ; 0=上 1=右 2=下 3=左
@q      = internal global [4 x i32] zeroinitializer      ; 方向入力キュー
@qn     = internal global i32 0
@fx     = internal global i32 0
@fy     = internal global i32 0
@score  = internal global i32 0
@best   = internal global i32 0
@alive  = internal global i32 1        ; 1=プレイ中 0=死亡 2=完全制覇
@paused = internal global i32 0
@quit   = internal global i32 0
@retry  = internal global i32 0
@demo   = internal global i32 0        ; 1=自動操縦デモ
@seed   = internal global i32 2463534242

; ---- 文字列 ------------------------------------------------------------------
@s_init  = internal constant [19 x i8] c"\1B[?1049h\1B[?25l\1B[2J\00"
@s_fini  = internal constant [19 x i8] c"\1B[0m\1B[?25h\1B[?1049l\00"
@s_home  = internal constant [4 x i8]  c"\1B[H\00"
@s_clear = internal constant [8 x i8]  c"\1B[2J\1B[H\00"
@s_eol   = internal constant [10 x i8] c"\1B[0m\1B[K\0D\0A\00"
@s_eos   = internal constant [8 x i8]  c"\1B[0m\1B[J\00"
@s_crlf  = internal constant [3 x i8]  c"\0D\0A\00"
@s_pad   = internal constant [7 x i8]  c"      \00"

; セルの種類: 0=空 1=壁 2=胴体 3=頭 4=エサ 5=死んだ頭
@c0 = internal constant [5 x i8]  c"\1B[0m\00"
@c1 = internal constant [9 x i8]  c"\1B[0;100m\00"
@c2 = internal constant [8 x i8]  c"\1B[0;42m\00"
@c3 = internal constant [12 x i8] c"\1B[0;30;102m\00"
@c4 = internal constant [13 x i8] c"\1B[0;1;97;41m\00"
@c5 = internal constant [13 x i8] c"\1B[0;1;30;43m\00"
@t_blank = internal constant [3 x i8] c"  \00"
@t_eyes  = internal constant [3 x i8] c"oo\00"
@t_food  = internal constant [3 x i8] c"<>\00"
@t_dead  = internal constant [3 x i8] c"xx\00"
@kind_color = internal constant [6 x ptr] [ptr @c0, ptr @c1, ptr @c2, ptr @c3, ptr @c4, ptr @c5]
@kind_text  = internal constant [6 x ptr] [ptr @t_blank, ptr @t_blank, ptr @t_blank, ptr @t_eyes, ptr @t_food, ptr @t_dead]
; SNAKE_ASCII=1 のときは色なしでも見える文字で描く
@t_wall  = internal constant [3 x i8] c"##\00"
@t_body  = internal constant [3 x i8] c"[]\00"
@kind_text_ascii = internal constant [6 x ptr] [ptr @t_blank, ptr @t_wall, ptr @t_body, ptr @t_eyes, ptr @t_food, ptr @t_dead]
@text_tbl = internal global ptr @kind_text
@s_env_ascii = internal constant [12 x i8] c"SNAKE_ASCII\00"
@s_env_demo  = internal constant [11 x i8] c"SNAKE_DEMO\00"

@s_hdr1   = internal constant [42 x i8] c"\1B[0;1;92m  LLVM IR SNAKE \1B[0m  スコア \00"
@s_hdr2   = internal constant [13 x i8] c"  ベスト \00"
@s_hdr3   = internal constant [13 x i8] c"  レベル \00"
@s_help   = internal constant [65 x i8] c"\1B[2m  移動: WASD / 矢印 / HJKL   P: 一時停止   Q: 終了\00"
@s_paused = internal constant [44 x i8] c"\1B[1;93m  ** 一時停止中 **  P で再開\00"
@s_over   = internal constant [53 x i8] c"\1B[1;91m  GAME OVER!\1B[0m  R: もう一度   Q: 終了\00"
@s_win    = internal constant [65 x i8] c"\1B[1;92m  PERFECT! 完全制覇!\1B[0m  R: もう一度   Q: 終了\00"
@s_demo   = internal constant [47 x i8] c"\1B[1;95m  DEMO: 自動操縦中\1B[0m   Q: 終了\00"

; タイトル画面のロゴ ('#' がヘビの胴体ブロックになる)
@logo0 = internal constant [30 x i8] c" #### #   #  ###  #   # #####\00"
@logo1 = internal constant [30 x i8] c"#     ##  # #   # #  #  #    \00"
@logo2 = internal constant [30 x i8] c" ###  # # # ##### ###   #### \00"
@logo3 = internal constant [30 x i8] c"    # #  ## #   # #  #  #    \00"
@logo4 = internal constant [30 x i8] c"####  #   # #   # #   # #####\00"
@s_sub    = internal constant [62 x i8] c"\0D\0A      \1B[1;96mLLVM IR 直書きスネークゲーム\1B[0m\0D\0A\0D\0A\00"
@s_keys1  = internal constant [47 x i8] c"      移動    : WASD / 矢印キー / HJKL\0D\0A\00"
@s_keys2  = internal constant [39 x i8] c"      一時停止: P / スペース\0D\0A\00"
@s_keys3  = internal constant [24 x i8] c"      終了    : Q\0D\0A\0D\0A\00"
@s_press  = internal constant [62 x i8] c"      \1B[1;93m>> 何かキーを押してスタート <<\1B[0m\0D\0A\00"

@s_bye1  = internal constant [56 x i8] c"遊んでくれてありがとう! ベストスコア: \00"
@s_bye2  = internal constant [2 x i8]  c"\0A\00"
@s_notty = internal constant [54 x i8] c"エラー: 端末(TTY)上で実行してください\0A\00"

; =============================================================================
;  出力
; =============================================================================

; NUL 終端文字列を出力バッファに追記
define internal void @emit(ptr %s) {
entry:
  %base = load i64, ptr @scr_len
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %copy ]
  %src = getelementptr inbounds i8, ptr %s, i64 %i
  %c = load i8, ptr %src
  %is.nul = icmp eq i8 %c, 0
  br i1 %is.nul, label %done, label %copy
copy:
  %pos = add i64 %base, %i
  %dst = getelementptr inbounds [65536 x i8], ptr @scr, i64 0, i64 %pos
  store i8 %c, ptr %dst
  %i.next = add i64 %i, 1
  br label %loop
done:
  %newlen = add i64 %base, %i
  store i64 %newlen, ptr @scr_len
  ret void
}

; 非負整数を 10 進で追記 (自前 itoa)
define internal void @emit_int(i32 %n) {
entry:
  %term = getelementptr inbounds [32 x i8], ptr @numbuf, i64 0, i64 15
  store i8 0, ptr %term
  br label %loop
loop:
  %v = phi i32 [ %n, %entry ], [ %quo, %loop ]
  %pos = phi i64 [ 15, %entry ], [ %pos.dec, %loop ]
  %quo = udiv i32 %v, 10
  %rem = urem i32 %v, 10
  %rem8 = trunc i32 %rem to i8
  %ch = add i8 %rem8, 48
  %pos.dec = sub i64 %pos, 1
  %slot = getelementptr inbounds [32 x i8], ptr @numbuf, i64 0, i64 %pos.dec
  store i8 %ch, ptr %slot
  %fin = icmp eq i32 %quo, 0
  br i1 %fin, label %out, label %loop
out:
  %start = getelementptr inbounds [32 x i8], ptr @numbuf, i64 0, i64 %pos.dec
  call void @emit(ptr %start)
  ret void
}

; バッファを stdout に書き出す
define internal void @flush() {
entry:
  %n = load i64, ptr @scr_len
  br label %loop
loop:
  %off = phi i64 [ 0, %entry ], [ %off.next, %wrote ]
  %left = sub i64 %n, %off
  %more = icmp sgt i64 %left, 0
  br i1 %more, label %do, label %done
do:
  %p = getelementptr inbounds i8, ptr @scr, i64 %off
  %w = call i64 @write(i32 1, ptr %p, i64 %left)
  %ok = icmp sgt i64 %w, 0
  br i1 %ok, label %wrote, label %done
wrote:
  %off.next = add i64 %off, %w
  br label %loop
done:
  store i64 0, ptr @scr_len
  ret void
}

; 1 セル (全角 2 桁分) を描く。色は変化したときだけ出力する
define internal void @cell(i32 %k) {
entry:
  %last = load i32, ptr @last_kind
  %same = icmp eq i32 %last, %k
  %k64 = sext i32 %k to i64
  br i1 %same, label %text, label %color
color:
  %cp = getelementptr inbounds [6 x ptr], ptr @kind_color, i64 0, i64 %k64
  %cs = load ptr, ptr %cp
  call void @emit(ptr %cs)
  store i32 %k, ptr @last_kind
  br label %text
text:
  %tbl = load ptr, ptr @text_tbl
  %tp = getelementptr inbounds [6 x ptr], ptr %tbl, i64 0, i64 %k64
  %ts = load ptr, ptr %tp
  call void @emit(ptr %ts)
  ret void
}

define internal void @endline() {
entry:
  call void @emit(ptr @s_eol)
  store i32 -1, ptr @last_kind
  ret void
}

define internal void @wall_row() {
entry:
  br label %loop
loop:
  %i = phi i32 [ 0, %entry ], [ %i.next, %loop ]
  call void @cell(i32 1)
  %i.next = add i32 %i, 1
  %fin = icmp eq i32 %i.next, 32
  br i1 %fin, label %done, label %loop
done:
  call void @endline()
  ret void
}

; ロゴ 1 行: '#' を胴体ブロック、それ以外を空白として描く
define internal void @logo_row(ptr %s) {
entry:
  call void @emit(ptr @s_pad)
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %draw ]
  %p = getelementptr inbounds i8, ptr %s, i64 %i
  %c = load i8, ptr %p
  %is.nul = icmp eq i8 %c, 0
  br i1 %is.nul, label %done, label %draw
draw:
  %is.hash = icmp eq i8 %c, 35
  %k = select i1 %is.hash, i32 2, i32 0
  call void @cell(i32 %k)
  %i.next = add i64 %i, 1
  br label %loop
done:
  call void @endline()
  ret void
}

; =============================================================================
;  端末
; =============================================================================

define internal i1 @term_setup() {
entry:
  %r = call i32 @tcgetattr(i32 0, ptr @orig_tio)
  %ok = icmp eq i32 %r, 0
  br i1 %ok, label %raw, label %fail
fail:
  ret i1 false
raw:
  call void @llvm.memcpy.p0.p0.i64(ptr @raw_tio, ptr @orig_tio, i64 128, i1 false)
  ; c_lflag &= ~(ECHO 0x8 | ISIG 0x80 | ICANON 0x100 | IEXTEN 0x400)
  %lp = getelementptr inbounds i8, ptr @raw_tio, i64 24
  %lflag = load i64, ptr %lp, align 8
  %lflag.raw = and i64 %lflag, -1417
  store i64 %lflag.raw, ptr %lp, align 8
  ; c_cc[VMIN] = 0, c_cc[VTIME] = 0  -> read() はノンブロッキング
  %vmin = getelementptr inbounds i8, ptr @raw_tio, i64 48
  store i8 0, ptr %vmin
  %vtime = getelementptr inbounds i8, ptr @raw_tio, i64 49
  store i8 0, ptr %vtime
  %r2 = call i32 @tcsetattr(i32 0, i32 0, ptr @raw_tio)
  call void @emit(ptr @s_init)
  call void @flush()
  ret i1 true
}

define internal void @term_restore() {
entry:
  call void @emit(ptr @s_fini)
  call void @flush()
  %r = call i32 @tcsetattr(i32 0, i32 0, ptr @orig_tio)
  ret void
}

; =============================================================================
;  乱数 (xorshift32)
; =============================================================================

define internal i32 @rng() {
entry:
  %x0 = load i32, ptr @seed
  %a = shl i32 %x0, 13
  %x1 = xor i32 %x0, %a
  %b = lshr i32 %x1, 17
  %x2 = xor i32 %x1, %b
  %c = shl i32 %x2, 5
  %x3 = xor i32 %x2, %c
  store i32 %x3, ptr @seed
  ret i32 %x3
}

; =============================================================================
;  入力
; =============================================================================

; 方向入力をキューに積む (逆走・重複は捨てる)
define internal void @try_dir(i32 %d) {
entry:
  %pa = load i32, ptr @paused
  %is.paused = icmp ne i32 %pa, 0
  br i1 %is.paused, label %done, label %look
look:
  %qn = load i32, ptr @qn
  %has = icmp sgt i32 %qn, 0
  br i1 %has, label %from.q, label %from.dir
from.q:
  %li = sub i32 %qn, 1
  %li64 = sext i32 %li to i64
  %lqp = getelementptr inbounds [4 x i32], ptr @q, i64 0, i64 %li64
  %lq = load i32, ptr %lqp
  br label %check
from.dir:
  %ld = load i32, ptr @dir
  br label %check
check:
  %last = phi i32 [ %lq, %from.q ], [ %ld, %from.dir ]
  %same = icmp eq i32 %d, %last
  %opp = xor i32 %last, 2
  %is.opp = icmp eq i32 %d, %opp
  %full = icmp sge i32 %qn, 3
  %bad0 = or i1 %same, %is.opp
  %bad = or i1 %bad0, %full
  br i1 %bad, label %done, label %push
push:
  %qn64 = sext i32 %qn to i64
  %slot = getelementptr inbounds [4 x i32], ptr @q, i64 0, i64 %qn64
  store i32 %d, ptr %slot
  %qn.inc = add i32 %qn, 1
  store i32 %qn.inc, ptr @qn
  br label %done
done:
  ret void
}

; ESC [ A..D
define internal void @arrow_key(i8 %c) {
entry:
  switch i8 %c, label %done [
    i8 65, label %up
    i8 66, label %down
    i8 67, label %right
    i8 68, label %left
  ]
up:
  call void @try_dir(i32 0)
  br label %done
right:
  call void @try_dir(i32 1)
  br label %done
down:
  call void @try_dir(i32 2)
  br label %done
left:
  call void @try_dir(i32 3)
  br label %done
done:
  ret void
}

define internal void @handle_key(i8 %c) {
entry:
  switch i8 %c, label %done [
    i8 119, label %up      ; w
    i8 87,  label %up      ; W
    i8 107, label %up      ; k
    i8 75,  label %up      ; K
    i8 100, label %right   ; d
    i8 68,  label %right   ; D
    i8 108, label %right   ; l
    i8 76,  label %right   ; L
    i8 115, label %down    ; s
    i8 83,  label %down    ; S
    i8 106, label %down    ; j
    i8 74,  label %down    ; J
    i8 97,  label %left    ; a
    i8 65,  label %left    ; A
    i8 104, label %left    ; h
    i8 72,  label %left    ; H
    i8 112, label %pause   ; p
    i8 80,  label %pause   ; P
    i8 32,  label %pause   ; space
    i8 113, label %quit    ; q
    i8 81,  label %quit    ; Q
    i8 3,   label %quit    ; Ctrl-C
    i8 114, label %retry   ; r
    i8 82,  label %retry   ; R
  ]
up:
  call void @try_dir(i32 0)
  br label %done
right:
  call void @try_dir(i32 1)
  br label %done
down:
  call void @try_dir(i32 2)
  br label %done
left:
  call void @try_dir(i32 3)
  br label %done
pause:
  %al = load i32, ptr @alive
  %playing = icmp eq i32 %al, 1
  br i1 %playing, label %toggle, label %done
toggle:
  %pa = load i32, ptr @paused
  %pa.t = xor i32 %pa, 1
  store i32 %pa.t, ptr @paused
  br label %done
quit:
  store i32 1, ptr @quit
  br label %done
retry:
  store i32 1, ptr @retry
  br label %done
done:
  ret void
}

; 溜まっているキー入力をすべて処理する
define internal void @poll_input() {
entry:
  %n = call i64 @read(i32 0, ptr @inbuf, i64 32)
  %got = icmp sgt i64 %n, 0
  br i1 %got, label %loop, label %done
loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %cont ]
  %p = getelementptr inbounds [32 x i8], ptr @inbuf, i64 0, i64 %i
  %c = load i8, ptr %p
  %is.esc = icmp eq i8 %c, 27
  br i1 %is.esc, label %esc, label %plain
esc:
  %i2 = add i64 %i, 2
  %fits = icmp slt i64 %i2, %n
  br i1 %fits, label %esc2, label %plain
esc2:
  %i1 = add i64 %i, 1
  %p1 = getelementptr inbounds [32 x i8], ptr @inbuf, i64 0, i64 %i1
  %c1 = load i8, ptr %p1
  %is.csi = icmp eq i8 %c1, 91     ; '['
  %is.ss3 = icmp eq i8 %c1, 79     ; 'O'
  %is.seq = or i1 %is.csi, %is.ss3
  br i1 %is.seq, label %arrow, label %plain
arrow:
  %p2 = getelementptr inbounds [32 x i8], ptr @inbuf, i64 0, i64 %i2
  %c2 = load i8, ptr %p2
  call void @arrow_key(i8 %c2)
  %i.a = add i64 %i, 3
  br label %cont
plain:
  call void @handle_key(i8 %c)
  %i.b = add i64 %i, 1
  br label %cont
cont:
  %i.next = phi i64 [ %i.a, %arrow ], [ %i.b, %plain ]
  %more = icmp slt i64 %i.next, %n
  br i1 %more, label %loop, label %done
done:
  ret void
}

; =============================================================================
;  ゲームロジック
; =============================================================================

define internal void @update_best() {
entry:
  %s = load i32, ptr @score
  %b = load i32, ptr @best
  %gt = icmp sgt i32 %s, %b
  br i1 %gt, label %set, label %done
set:
  store i32 %s, ptr @best
  br label %done
done:
  ret void
}

define internal i32 @level() {
entry:
  %s = load i32, ptr @score
  %q = sdiv i32 %s, 5
  %l = add i32 %q, 1
  %over = icmp sgt i32 %l, 10
  %r = select i1 %over, i32 10, i32 %l
  ret i32 %r
}

; 1 手あたりの待ち時間 (us)。レベルが上がるほど速くなる
define internal i32 @delay() {
entry:
  %l = call i32 @level()
  %l0 = sub i32 %l, 1
  %cut = mul i32 %l0, 12000
  %d = sub i32 160000, %cut
  ret i32 %d
}

; 空きマスからランダムにエサを置く (空きマスの r 番目を選ぶので必ず終わる)
define internal void @place_food() {
entry:
  %len = load i32, ptr @len
  %free = sub i32 540, %len
  %r0 = call i32 @rng()
  %r = urem i32 %r0, %free
  br label %loop
loop:
  %i = phi i32 [ 0, %entry ], [ %i.next, %next ]
  %k = phi i32 [ %r, %entry ], [ %k.next, %next ]
  %i64 = sext i32 %i to i64
  %gp = getelementptr inbounds [540 x i8], ptr @grid, i64 0, i64 %i64
  %g = load i8, ptr %gp
  %empty = icmp eq i8 %g, 0
  br i1 %empty, label %is.empty, label %next
is.empty:
  %hit = icmp eq i32 %k, 0
  br i1 %hit, label %found, label %dec
dec:
  %k.dec = sub i32 %k, 1
  br label %next
next:
  %k.next = phi i32 [ %k, %loop ], [ %k.dec, %dec ]
  %i.next = add i32 %i, 1
  %end = icmp eq i32 %i.next, 540
  br i1 %end, label %none, label %loop
found:
  %x = urem i32 %i, 30
  %y = udiv i32 %i, 30
  store i32 %x, ptr @fx
  store i32 %y, ptr @fy
  ret void
none:
  store i32 -1, ptr @fx
  store i32 -1, ptr @fy
  ret void
}

define internal void @init_game() {
entry:
  call void @llvm.memset.p0.i64(ptr @grid, i8 0, i64 540, i1 false)
  ; 長さ 3 のヘビを (5,9) (6,9) (7,9) に置く。頭は index 2
  %sx1 = getelementptr inbounds [540 x i32], ptr @sx, i64 0, i64 1
  %sx2 = getelementptr inbounds [540 x i32], ptr @sx, i64 0, i64 2
  %sy1 = getelementptr inbounds [540 x i32], ptr @sy, i64 0, i64 1
  %sy2 = getelementptr inbounds [540 x i32], ptr @sy, i64 0, i64 2
  store i32 5, ptr @sx
  store i32 6, ptr %sx1
  store i32 7, ptr %sx2
  store i32 9, ptr @sy
  store i32 9, ptr %sy1
  store i32 9, ptr %sy2
  %g0 = getelementptr inbounds [540 x i8], ptr @grid, i64 0, i64 275
  %g1 = getelementptr inbounds [540 x i8], ptr @grid, i64 0, i64 276
  %g2 = getelementptr inbounds [540 x i8], ptr @grid, i64 0, i64 277
  store i8 1, ptr %g0
  store i8 1, ptr %g1
  store i8 1, ptr %g2
  store i32 2, ptr @head
  store i32 3, ptr @len
  store i32 1, ptr @dir
  store i32 0, ptr @qn
  store i32 0, ptr @score
  store i32 1, ptr @alive
  store i32 0, ptr @paused
  store i32 0, ptr @retry
  call void @place_food()
  ret void
}

; 頭から方向 d に 1 マス進んだ座標を { x, y } で返す
define internal { i32, i32 } @neighbor(i32 %d) {
entry:
  %h = load i32, ptr @head
  %h64 = sext i32 %h to i64
  %hxp = getelementptr inbounds [540 x i32], ptr @sx, i64 0, i64 %h64
  %hyp = getelementptr inbounds [540 x i32], ptr @sy, i64 0, i64 %h64
  %hx = load i32, ptr %hxp
  %hy = load i32, ptr %hyp
  %is.u = icmp eq i32 %d, 0
  %is.r = icmp eq i32 %d, 1
  %is.d = icmp eq i32 %d, 2
  %is.l = icmp eq i32 %d, 3
  %dx0 = select i1 %is.l, i32 -1, i32 0
  %dx = select i1 %is.r, i32 1, i32 %dx0
  %dy0 = select i1 %is.u, i32 -1, i32 0
  %dy = select i1 %is.d, i32 1, i32 %dy0
  %nx = add i32 %hx, %dx
  %ny = add i32 %hy, %dy
  %r0 = insertvalue { i32, i32 } poison, i32 %nx, 0
  %r1 = insertvalue { i32, i32 } %r0, i32 %ny, 1
  ret { i32, i32 } %r1
}

; 自動操縦用: 方向 d に進んだときのコスト (危険なら 1000000、安全ならエサまでのマンハッタン距離)
define internal i32 @dir_cost(i32 %d) {
entry:
  %np = call { i32, i32 } @neighbor(i32 %d)
  %nx = extractvalue { i32, i32 } %np, 0
  %ny = extractvalue { i32, i32 } %np, 1
  %oob.x = icmp uge i32 %nx, 30
  %oob.y = icmp uge i32 %ny, 18
  %oob = or i1 %oob.x, %oob.y
  br i1 %oob, label %unsafe, label %inside
inside:
  %nyw = mul i32 %ny, 30
  %idx = add i32 %nyw, %nx
  %idx64 = sext i32 %idx to i64
  %gp = getelementptr inbounds [540 x i8], ptr @grid, i64 0, i64 %idx64
  %g = load i8, ptr %gp
  %occ = icmp ne i8 %g, 0
  br i1 %occ, label %unsafe, label %safe
safe:
  %fx = load i32, ptr @fx
  %fy = load i32, ptr @fy
  %ddx = sub i32 %nx, %fx
  %ddy = sub i32 %ny, %fy
  %ax = call i32 @llvm.abs.i32(i32 %ddx, i1 false)
  %ay = call i32 @llvm.abs.i32(i32 %ddy, i1 false)
  %dist = add i32 %ax, %ay
  ret i32 %dist
unsafe:
  ret i32 1000000
}

; 4 方向のうち最もコストの低い方向を選ぶ (すべて危険なら直進)
define internal void @auto_dir() {
entry:
  store i32 0, ptr @qn
  %cur = load i32, ptr @dir
  %cur.cost = call i32 @dir_cost(i32 %cur)
  br label %loop
loop:
  %d = phi i32 [ 0, %entry ], [ %d.next, %loop ]
  %best.d = phi i32 [ %cur, %entry ], [ %best.d.n, %loop ]
  %best.c = phi i32 [ %cur.cost, %entry ], [ %best.c.n, %loop ]
  %c = call i32 @dir_cost(i32 %d)
  %better = icmp slt i32 %c, %best.c
  %best.d.n = select i1 %better, i32 %d, i32 %best.d
  %best.c.n = select i1 %better, i32 %c, i32 %best.c
  %d.next = add i32 %d, 1
  %fin = icmp eq i32 %d.next, 4
  br i1 %fin, label %done, label %loop
done:
  store i32 %best.d.n, ptr @dir
  ret void
}

; ヘビを 1 マス進める
define internal void @step() {
entry:
  %dm = load i32, ptr @demo
  %is.demo = icmp ne i32 %dm, 0
  br i1 %is.demo, label %autopilot, label %manual
autopilot:
  call void @auto_dir()
  br label %manual
manual:
  %qn = load i32, ptr @qn
  %has = icmp sgt i32 %qn, 0
  br i1 %has, label %dequeue, label %move
dequeue:
  %q0 = load i32, ptr @q
  store i32 %q0, ptr @dir
  %q1p = getelementptr inbounds [4 x i32], ptr @q, i64 0, i64 1
  %q2p = getelementptr inbounds [4 x i32], ptr @q, i64 0, i64 2
  %q1 = load i32, ptr %q1p
  %q2 = load i32, ptr %q2p
  store i32 %q1, ptr @q
  store i32 %q2, ptr %q1p
  %qn.dec = sub i32 %qn, 1
  store i32 %qn.dec, ptr @qn
  br label %move
move:
  %d = load i32, ptr @dir
  %h = load i32, ptr @head
  %np = call { i32, i32 } @neighbor(i32 %d)
  %nx = extractvalue { i32, i32 } %np, 0
  %ny = extractvalue { i32, i32 } %np, 1
  ; 符号なし比較で負の座標もまとめて壁判定
  %oob.x = icmp uge i32 %nx, 30
  %oob.y = icmp uge i32 %ny, 18
  %oob = or i1 %oob.x, %oob.y
  br i1 %oob, label %die, label %inside
inside:
  %fx = load i32, ptr @fx
  %fy = load i32, ptr @fy
  %eat.x = icmp eq i32 %nx, %fx
  %eat.y = icmp eq i32 %ny, %fy
  %eat = and i1 %eat.x, %eat.y
  br i1 %eat, label %check, label %drop.tail
drop.tail:
  ; エサを食べないときは先に尻尾を消す (尻尾のあった場所には進める)
  %len = load i32, ptr @len
  %t0 = sub i32 %h, %len
  %t1 = add i32 %t0, 541
  %tail = urem i32 %t1, 540
  %tail64 = sext i32 %tail to i64
  %txp = getelementptr inbounds [540 x i32], ptr @sx, i64 0, i64 %tail64
  %typ = getelementptr inbounds [540 x i32], ptr @sy, i64 0, i64 %tail64
  %tx = load i32, ptr %txp
  %ty = load i32, ptr %typ
  %tyw = mul i32 %ty, 30
  %tidx = add i32 %tyw, %tx
  %tidx64 = sext i32 %tidx to i64
  %tgp = getelementptr inbounds [540 x i8], ptr @grid, i64 0, i64 %tidx64
  store i8 0, ptr %tgp
  br label %check
check:
  %tsave = phi i32 [ -1, %inside ], [ %tidx, %drop.tail ]
  %nyw = mul i32 %ny, 30
  %nidx = add i32 %nyw, %nx
  %nidx64 = sext i32 %nidx to i64
  %ngp = getelementptr inbounds [540 x i8], ptr @grid, i64 0, i64 %nidx64
  %ng = load i8, ptr %ngp
  %bit = icmp ne i8 %ng, 0
  br i1 %bit, label %bite, label %advance
bite:
  ; 自分を噛んだ: 消した尻尾を描画用に戻しておく
  %had.tail = icmp sge i32 %tsave, 0
  br i1 %had.tail, label %restore.tail, label %die
restore.tail:
  %ts64 = sext i32 %tsave to i64
  %rtp = getelementptr inbounds [540 x i8], ptr @grid, i64 0, i64 %ts64
  store i8 1, ptr %rtp
  br label %die
advance:
  %nh0 = add i32 %h, 1
  %nh = urem i32 %nh0, 540
  %nh64 = sext i32 %nh to i64
  %nxp = getelementptr inbounds [540 x i32], ptr @sx, i64 0, i64 %nh64
  %nyp = getelementptr inbounds [540 x i32], ptr @sy, i64 0, i64 %nh64
  store i32 %nx, ptr %nxp
  store i32 %ny, ptr %nyp
  store i8 1, ptr %ngp
  store i32 %nh, ptr @head
  br i1 %eat, label %grow, label %done
grow:
  %len2 = load i32, ptr @len
  %len3 = add i32 %len2, 1
  store i32 %len3, ptr @len
  %sc = load i32, ptr @score
  %sc1 = add i32 %sc, 1
  store i32 %sc1, ptr @score
  call void @update_best()
  %full = icmp eq i32 %len3, 540
  br i1 %full, label %win, label %food
food:
  call void @place_food()
  br label %done
win:
  store i32 2, ptr @alive
  store i32 -1, ptr @fx
  store i32 -1, ptr @fy
  br label %done
die:
  store i32 0, ptr @alive
  br label %done
done:
  ret void
}

; =============================================================================
;  描画
; =============================================================================

define internal i32 @cell_kind(i32 %x, i32 %y) {
entry:
  %fx = load i32, ptr @fx
  %fy = load i32, ptr @fy
  %f.x = icmp eq i32 %x, %fx
  %f.y = icmp eq i32 %y, %fy
  %is.food = and i1 %f.x, %f.y
  br i1 %is.food, label %food, label %not.food
food:
  ret i32 4
not.food:
  %h = load i32, ptr @head
  %h64 = sext i32 %h to i64
  %hxp = getelementptr inbounds [540 x i32], ptr @sx, i64 0, i64 %h64
  %hyp = getelementptr inbounds [540 x i32], ptr @sy, i64 0, i64 %h64
  %hx = load i32, ptr %hxp
  %hy = load i32, ptr %hyp
  %h.x = icmp eq i32 %x, %hx
  %h.y = icmp eq i32 %y, %hy
  %is.head = and i1 %h.x, %h.y
  br i1 %is.head, label %hd, label %body
hd:
  %al = load i32, ptr @alive
  %dead = icmp eq i32 %al, 0
  %hk = select i1 %dead, i32 5, i32 3
  ret i32 %hk
body:
  %yw = mul i32 %y, 30
  %idx = add i32 %yw, %x
  %idx64 = sext i32 %idx to i64
  %gp = getelementptr inbounds [540 x i8], ptr @grid, i64 0, i64 %idx64
  %g = load i8, ptr %gp
  %occ = icmp ne i8 %g, 0
  %bk = select i1 %occ, i32 2, i32 0
  ret i32 %bk
}

define internal void @render() {
entry:
  call void @emit(ptr @s_home)
  ; ヘッダ
  call void @emit(ptr @s_hdr1)
  %sc = load i32, ptr @score
  call void @emit_int(i32 %sc)
  call void @emit(ptr @s_hdr2)
  %bs = load i32, ptr @best
  call void @emit_int(i32 %bs)
  call void @emit(ptr @s_hdr3)
  %lv = call i32 @level()
  call void @emit_int(i32 %lv)
  call void @endline()
  ; 盤面
  call void @wall_row()
  br label %row
row:
  %y = phi i32 [ 0, %entry ], [ %y.next, %row.end ]
  call void @cell(i32 1)
  br label %col
col:
  %x = phi i32 [ 0, %row ], [ %x.next, %col ]
  %k = call i32 @cell_kind(i32 %x, i32 %y)
  call void @cell(i32 %k)
  %x.next = add i32 %x, 1
  %x.fin = icmp eq i32 %x.next, 30
  br i1 %x.fin, label %row.end, label %col
row.end:
  call void @cell(i32 1)
  call void @endline()
  %y.next = add i32 %y, 1
  %y.fin = icmp eq i32 %y.next, 18
  br i1 %y.fin, label %bottom, label %row
bottom:
  call void @wall_row()
  ; ステータス行
  %al = load i32, ptr @alive
  %pa = load i32, ptr @paused
  %is.dead = icmp eq i32 %al, 0
  %is.won = icmp eq i32 %al, 2
  %is.paused = icmp ne i32 %pa, 0
  %dm = load i32, ptr @demo
  %is.demo = icmp ne i32 %dm, 0
  %m0 = select i1 %is.demo, ptr @s_demo, ptr @s_help
  %m1 = select i1 %is.paused, ptr @s_paused, ptr %m0
  %m2 = select i1 %is.won, ptr @s_win, ptr %m1
  %m3 = select i1 %is.dead, ptr @s_over, ptr %m2
  call void @emit(ptr %m3)
  call void @endline()
  call void @emit(ptr @s_eos)
  call void @flush()
  ret void
}

define internal void @title_screen() {
entry:
  call void @emit(ptr @s_clear)
  call void @emit(ptr @s_crlf)
  call void @emit(ptr @s_crlf)
  call void @logo_row(ptr @logo0)
  call void @logo_row(ptr @logo1)
  call void @logo_row(ptr @logo2)
  call void @logo_row(ptr @logo3)
  call void @logo_row(ptr @logo4)
  call void @emit(ptr @s_sub)
  call void @emit(ptr @s_keys1)
  call void @emit(ptr @s_keys2)
  call void @emit(ptr @s_keys3)
  call void @emit(ptr @s_press)
  call void @flush()
  br label %wait
wait:
  %n = call i64 @read(i32 0, ptr @inbuf, i64 32)
  %got = icmp sgt i64 %n, 0
  br i1 %got, label %key, label %sleep
sleep:
  %u = call i32 @usleep(i32 30000)
  br label %wait
key:
  %c = load i8, ptr @inbuf
  %is.q = icmp eq i8 %c, 113
  %is.Q = icmp eq i8 %c, 81
  %is.cc = icmp eq i8 %c, 3
  %qq = or i1 %is.q, %is.Q
  %want.quit = or i1 %qq, %is.cc
  br i1 %want.quit, label %quit, label %done
quit:
  store i32 1, ptr @quit
  br label %done
done:
  ret void
}

; =============================================================================
;  main
; =============================================================================

define i32 @main() {
entry:
  %tty = call i1 @term_setup()
  br i1 %tty, label %start, label %no.tty
no.tty:
  call void @emit(ptr @s_notty)
  call void @flush()
  ret i32 1
start:
  ; 乱数の種: time() ^ (pid << 16)、0 にならないよう | 1
  %t = call i64 @time(ptr null)
  %t32 = trunc i64 %t to i32
  %pid = call i32 @getpid()
  %pid.s = shl i32 %pid, 16
  %seed0 = xor i32 %t32, %pid.s
  %seed1 = or i32 %seed0, 1
  store i32 %seed1, ptr @seed
  %env = call ptr @getenv(ptr @s_env_ascii)
  %ascii = icmp ne ptr %env, null
  br i1 %ascii, label %use.ascii, label %demo.check
use.ascii:
  store ptr @kind_text_ascii, ptr @text_tbl
  br label %demo.check
demo.check:
  %env2 = call ptr @getenv(ptr @s_env_demo)
  %want.demo = icmp ne ptr %env2, null
  br i1 %want.demo, label %use.demo, label %title
use.demo:
  store i32 1, ptr @demo
  br label %new.game
title:
  call void @title_screen()
  %q0 = load i32, ptr @quit
  %quit0 = icmp ne i32 %q0, 0
  br i1 %quit0, label %exit, label %new.game
new.game:
  call void @init_game()
  call void @emit(ptr @s_clear)
  br label %frame
frame:
  call void @poll_input()
  %q1 = load i32, ptr @quit
  %quit1 = icmp ne i32 %q1, 0
  br i1 %quit1, label %exit, label %check.pause
check.pause:
  %pa = load i32, ptr @paused
  %is.paused = icmp ne i32 %pa, 0
  br i1 %is.paused, label %paused, label %run
paused:
  call void @render()
  %u0 = call i32 @usleep(i32 50000)
  br label %frame
run:
  call void @step()
  call void @render()
  %al = load i32, ptr @alive
  %playing = icmp eq i32 %al, 1
  br i1 %playing, label %tick, label %over
tick:
  %dl = call i32 @delay()
  %u1 = call i32 @usleep(i32 %dl)
  br label %frame
over:
  ; 押しっぱなしのキーで即リトライしないよう少し待ってから入力を捨てる
  %u2 = call i32 @usleep(i32 500000)
  %drain = call i64 @read(i32 0, ptr @inbuf, i64 32)
  store i32 0, ptr @retry
  %dm = load i32, ptr @demo
  %is.demo = icmp ne i32 %dm, 0
  br i1 %is.demo, label %demo.again, label %wait
demo.again:
  ; デモは少し待って自動で再スタート
  %u4 = call i32 @usleep(i32 1500000)
  br label %new.game
wait:
  call void @poll_input()
  %q2 = load i32, ptr @quit
  %quit2 = icmp ne i32 %q2, 0
  br i1 %quit2, label %exit, label %check.retry
check.retry:
  %rt = load i32, ptr @retry
  %again = icmp ne i32 %rt, 0
  br i1 %again, label %new.game, label %wait.more
wait.more:
  %u3 = call i32 @usleep(i32 30000)
  br label %wait
exit:
  call void @term_restore()
  call void @emit(ptr @s_bye1)
  %b = load i32, ptr @best
  call void @emit_int(i32 %b)
  call void @emit(ptr @s_bye2)
  call void @flush()
  ret i32 0
}
