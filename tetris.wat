;; =============================================================================
;; TETRIS GAME - Pure WebAssembly Implementation
;; =============================================================================
;; 
;; This WASM module handles EVERYTHING:
;; - Game state management
;; - Piece physics and collision
;; - Line clearing and scoring  
;; - Full framebuffer rendering (pixel-by-pixel)
;; - Color calculations
;; - Timing and animation
;;
;; JavaScript only provides:
;; - Module loading (required by browser)
;; - Copying framebuffer to canvas (WASM can't access DOM)
;; - Forwarding keyboard events (WASM can't access events)
;;
;; =============================================================================
;; MEMORY LAYOUT
;; =============================================================================
;; 
;; Page 0 (0-65535): Game State
;;   0-199:      Grid cells (10x20 = 200 bytes)
;;   200-299:    Game variables (piece state, score, etc.)
;;   300-523:    Piece shape definitions (7 pieces × 4 rotations × 8 bytes)
;;   524-600:    Reserved
;;
;; Pages 1-4 (65536+): Framebuffer
;;   Canvas: 320x640 pixels × 4 bytes (RGBA) = 819,200 bytes
;;   Starts at offset 65536 (page 1)
;;
;; =============================================================================

(module
  ;; 16 pages = 1MB memory (enough for framebuffer + game state)
  (memory (export "memory") 16)

  ;; ==========================================================================
  ;; CONSTANTS
  ;; ==========================================================================
  
  ;; Grid dimensions
  (global $GRID_WIDTH i32 (i32.const 10))
  (global $GRID_HEIGHT i32 (i32.const 20))
  (global $GRID_SIZE i32 (i32.const 200))
  
  ;; Cell size in pixels
  (global $CELL_SIZE i32 (i32.const 30))
  
  ;; Canvas dimensions
  (global $CANVAS_WIDTH i32 (i32.const 320))
  (global $CANVAS_HEIGHT i32 (i32.const 640))
  
  ;; Framebuffer offset (start of page 1)
  (global $FRAMEBUFFER_OFFSET i32 (i32.const 65536))
  
  ;; Game state memory addresses
  (global $ADDR_PIECE_TYPE i32 (i32.const 200))
  (global $ADDR_PIECE_X i32 (i32.const 204))
  (global $ADDR_PIECE_Y i32 (i32.const 208))
  (global $ADDR_PIECE_ROT i32 (i32.const 212))
  (global $ADDR_SCORE i32 (i32.const 216))
  (global $ADDR_LEVEL i32 (i32.const 220))
  (global $ADDR_LINES i32 (i32.const 224))
  (global $ADDR_GAME_OVER i32 (i32.const 228))
  (global $ADDR_NEXT_PIECE i32 (i32.const 232))
  (global $ADDR_DROP_TIMER i32 (i32.const 236))
  (global $ADDR_RANDOM_SEED i32 (i32.const 240))
  (global $ADDR_FRAME_COUNT i32 (i32.const 244))
  (global $ADDR_CLEAR_ANIM i32 (i32.const 248))
  (global $ADDR_CLEAR_ROWS i32 (i32.const 252))  ;; 4 bytes for up to 4 rows
  (global $ADDR_CLEAR_COUNT i32 (i32.const 256))
  
  ;; Piece definitions base address
  (global $ADDR_PIECES i32 (i32.const 300))

  ;; ==========================================================================
  ;; COLOR DEFINITIONS (RGBA - little endian = ABGR in memory)
  ;; ==========================================================================
  ;; Colors stored as i32: 0xAABBGGRR
  
  ;; Background color (dark blue-black)
  (global $COLOR_BG i32 (i32.const 0xFF0F0A0A))
  
  ;; Grid line color (subtle)
  (global $COLOR_GRID i32 (i32.const 0xFF1A1A1A))
  
  ;; Piece colors (bright, vibrant)
  ;; I = Cyan, O = Yellow, T = Purple, S = Green, Z = Red, J = Blue, L = Orange
  (global $COLOR_I i32 (i32.const 0xFFFFF500))      ;; Cyan #00F5FF
  (global $COLOR_O i32 (i32.const 0xFF00EAFF))      ;; Yellow #FFEA00
  (global $COLOR_T i32 (i32.const 0xFFFF00D0))      ;; Purple #D000FF
  (global $COLOR_S i32 (i32.const 0xFF6AFF00))      ;; Green #00FF6A
  (global $COLOR_Z i32 (i32.const 0xFF6633FF))      ;; Red #FF3366
  (global $COLOR_J i32 (i32.const 0xFFFF6633))      ;; Blue #3366FF
  (global $COLOR_L i32 (i32.const 0xFF0095FF))      ;; Orange #FF9500

  ;; ==========================================================================
  ;; HELPER: Get piece color by type (0-6)
  ;; ==========================================================================
  (func $get_piece_color (param $type i32) (result i32)
    (if (result i32) (i32.eq (local.get $type) (i32.const 0))
      (then (global.get $COLOR_I))
      (else (if (result i32) (i32.eq (local.get $type) (i32.const 1))
        (then (global.get $COLOR_O))
        (else (if (result i32) (i32.eq (local.get $type) (i32.const 2))
          (then (global.get $COLOR_T))
          (else (if (result i32) (i32.eq (local.get $type) (i32.const 3))
            (then (global.get $COLOR_S))
            (else (if (result i32) (i32.eq (local.get $type) (i32.const 4))
              (then (global.get $COLOR_Z))
              (else (if (result i32) (i32.eq (local.get $type) (i32.const 5))
                (then (global.get $COLOR_J))
                (else (global.get $COLOR_L))
              ))
            ))
          ))
        ))
      ))
    )
  )

  ;; Darker version of color (for shadows)
  (func $darken_color (param $color i32) (result i32)
    (i32.or
      (i32.const 0xFF000000)  ;; Keep alpha
      (i32.or
        (i32.shr_u (i32.and (local.get $color) (i32.const 0x00FF0000)) (i32.const 1))
        (i32.or
          (i32.shr_u (i32.and (local.get $color) (i32.const 0x0000FF00)) (i32.const 1))
          (i32.shr_u (i32.and (local.get $color) (i32.const 0x000000FF)) (i32.const 1))
        )
      )
    )
  )

  ;; Lighter version of color (for highlights)
  (func $lighten_color (param $color i32) (result i32)
    (local $r i32) (local $g i32) (local $b i32)
    (local.set $r (i32.and (local.get $color) (i32.const 0xFF)))
    (local.set $g (i32.shr_u (i32.and (local.get $color) (i32.const 0xFF00)) (i32.const 8)))
    (local.set $b (i32.shr_u (i32.and (local.get $color) (i32.const 0xFF0000)) (i32.const 16)))
    
    ;; Add 80 to each channel, cap at 255
    (local.set $r (if (result i32) (i32.gt_u (i32.add (local.get $r) (i32.const 80)) (i32.const 255))
      (then (i32.const 255)) (else (i32.add (local.get $r) (i32.const 80)))))
    (local.set $g (if (result i32) (i32.gt_u (i32.add (local.get $g) (i32.const 80)) (i32.const 255))
      (then (i32.const 255)) (else (i32.add (local.get $g) (i32.const 80)))))
    (local.set $b (if (result i32) (i32.gt_u (i32.add (local.get $b) (i32.const 80)) (i32.const 255))
      (then (i32.const 255)) (else (i32.add (local.get $b) (i32.const 80)))))
    
    (i32.or
      (i32.const 0xFF000000)
      (i32.or
        (i32.shl (local.get $b) (i32.const 16))
        (i32.or
          (i32.shl (local.get $g) (i32.const 8))
          (local.get $r)
        )
      )
    )
  )

  ;; ==========================================================================
  ;; FRAMEBUFFER OPERATIONS
  ;; ==========================================================================

  ;; Set a single pixel in the framebuffer
  (func $set_pixel (param $x i32) (param $y i32) (param $color i32)
    (if
      (i32.and
        (i32.and
          (i32.ge_s (local.get $x) (i32.const 0))
          (i32.lt_s (local.get $x) (global.get $CANVAS_WIDTH))
        )
        (i32.and
          (i32.ge_s (local.get $y) (i32.const 0))
          (i32.lt_s (local.get $y) (global.get $CANVAS_HEIGHT))
        )
      )
      (then
        (i32.store
          (i32.add
            (global.get $FRAMEBUFFER_OFFSET)
            (i32.shl
              (i32.add
                (i32.mul (local.get $y) (global.get $CANVAS_WIDTH))
                (local.get $x)
              )
              (i32.const 2)  ;; × 4 bytes per pixel
            )
          )
          (local.get $color)
        )
      )
    )
  )

  ;; Fill a rectangle with a color
  (func $fill_rect (param $x i32) (param $y i32) (param $w i32) (param $h i32) (param $color i32)
    (local $px i32) (local $py i32) (local $end_x i32) (local $end_y i32)
    
    (local.set $end_x (i32.add (local.get $x) (local.get $w)))
    (local.set $end_y (i32.add (local.get $y) (local.get $h)))
    
    (local.set $py (local.get $y))
    (block $break_y
      (loop $loop_y
        (br_if $break_y (i32.ge_s (local.get $py) (local.get $end_y)))
        
        (local.set $px (local.get $x))
        (block $break_x
          (loop $loop_x
            (br_if $break_x (i32.ge_s (local.get $px) (local.get $end_x)))
            (call $set_pixel (local.get $px) (local.get $py) (local.get $color))
            (local.set $px (i32.add (local.get $px) (i32.const 1)))
            (br $loop_x)
          )
        )
        
        (local.set $py (i32.add (local.get $py) (i32.const 1)))
        (br $loop_y)
      )
    )
  )

  ;; Draw a horizontal line
  (func $draw_hline (param $x i32) (param $y i32) (param $len i32) (param $color i32)
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $break
      (loop $loop
        (br_if $break (i32.ge_s (local.get $i) (local.get $len)))
        (call $set_pixel (i32.add (local.get $x) (local.get $i)) (local.get $y) (local.get $color))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)
      )
    )
  )

  ;; Draw a vertical line
  (func $draw_vline (param $x i32) (param $y i32) (param $len i32) (param $color i32)
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $break
      (loop $loop
        (br_if $break (i32.ge_s (local.get $i) (local.get $len)))
        (call $set_pixel (local.get $x) (i32.add (local.get $y) (local.get $i)) (local.get $color))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)
      )
    )
  )

  ;; ==========================================================================
  ;; GRID OPERATIONS
  ;; ==========================================================================

  (func $get_grid (param $x i32) (param $y i32) (result i32)
    (if (result i32)
      (i32.or
        (i32.or
          (i32.lt_s (local.get $x) (i32.const 0))
          (i32.ge_s (local.get $x) (global.get $GRID_WIDTH))
        )
        (i32.or
          (i32.lt_s (local.get $y) (i32.const 0))
          (i32.ge_s (local.get $y) (global.get $GRID_HEIGHT))
        )
      )
      (then (i32.const 1))
      (else
        (i32.load8_u
          (i32.add
            (i32.mul (local.get $y) (global.get $GRID_WIDTH))
            (local.get $x)
          )
        )
      )
    )
  )

  (func $set_grid (param $x i32) (param $y i32) (param $value i32)
    (if
      (i32.and
        (i32.and
          (i32.ge_s (local.get $x) (i32.const 0))
          (i32.lt_s (local.get $x) (global.get $GRID_WIDTH))
        )
        (i32.and
          (i32.ge_s (local.get $y) (i32.const 0))
          (i32.lt_s (local.get $y) (global.get $GRID_HEIGHT))
        )
      )
      (then
        (i32.store8
          (i32.add
            (i32.mul (local.get $y) (global.get $GRID_WIDTH))
            (local.get $x)
          )
          (local.get $value)
        )
      )
    )
  )

  ;; ==========================================================================
  ;; RANDOM NUMBER GENERATOR
  ;; ==========================================================================

  (func $random (result i32)
    (local $seed i32)
    (local.set $seed
      (i32.and
        (i32.add
          (i32.mul (i32.load (global.get $ADDR_RANDOM_SEED)) (i32.const 1103515245))
          (i32.const 12345)
        )
        (i32.const 0x7fffffff)
      )
    )
    (i32.store (global.get $ADDR_RANDOM_SEED) (local.get $seed))
    (i32.rem_u (local.get $seed) (i32.const 7))
  )

  ;; ==========================================================================
  ;; PIECE DEFINITIONS
  ;; ==========================================================================

  (func $init_pieces
    (local $base i32)
    (local.set $base (global.get $ADDR_PIECES))
    
    ;; I PIECE (type 0) - 4 rotations
    ;; Rot 0: ####
    (i32.store8 (i32.add (local.get $base) (i32.const 0)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 1)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 2)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 3)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 4)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 5)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 6)) (i32.const 3))
    (i32.store8 (i32.add (local.get $base) (i32.const 7)) (i32.const 0))
    ;; Rot 1: vertical
    (i32.store8 (i32.add (local.get $base) (i32.const 8)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 9)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 10)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 11)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 12)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 13)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 14)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 15)) (i32.const 3))
    ;; Rot 2: same as 0
    (i32.store8 (i32.add (local.get $base) (i32.const 16)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 17)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 18)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 19)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 20)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 21)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 22)) (i32.const 3))
    (i32.store8 (i32.add (local.get $base) (i32.const 23)) (i32.const 0))
    ;; Rot 3: same as 1
    (i32.store8 (i32.add (local.get $base) (i32.const 24)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 25)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 26)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 27)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 28)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 29)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 30)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 31)) (i32.const 3))

    ;; O PIECE (type 1) - all rotations same
    (i32.store8 (i32.add (local.get $base) (i32.const 32)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 33)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 34)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 35)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 36)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 37)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 38)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 39)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 40)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 41)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 42)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 43)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 44)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 45)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 46)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 47)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 48)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 49)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 50)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 51)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 52)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 53)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 54)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 55)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 56)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 57)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 58)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 59)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 60)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 61)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 62)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 63)) (i32.const 1))

    ;; T PIECE (type 2)
    ;; Rot 0: ###
    ;;         #
    (i32.store8 (i32.add (local.get $base) (i32.const 64)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 65)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 66)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 67)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 68)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 69)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 70)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 71)) (i32.const 1))
    ;; Rot 1
    (i32.store8 (i32.add (local.get $base) (i32.const 72)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 73)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 74)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 75)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 76)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 77)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 78)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 79)) (i32.const 2))
    ;; Rot 2
    (i32.store8 (i32.add (local.get $base) (i32.const 80)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 81)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 82)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 83)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 84)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 85)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 86)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 87)) (i32.const 1))
    ;; Rot 3
    (i32.store8 (i32.add (local.get $base) (i32.const 88)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 89)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 90)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 91)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 92)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 93)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 94)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 95)) (i32.const 2))

    ;; S PIECE (type 3)
    (i32.store8 (i32.add (local.get $base) (i32.const 96)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 97)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 98)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 99)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 100)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 101)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 102)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 103)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 104)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 105)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 106)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 107)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 108)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 109)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 110)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 111)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 112)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 113)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 114)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 115)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 116)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 117)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 118)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 119)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 120)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 121)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 122)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 123)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 124)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 125)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 126)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 127)) (i32.const 2))

    ;; Z PIECE (type 4)
    (i32.store8 (i32.add (local.get $base) (i32.const 128)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 129)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 130)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 131)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 132)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 133)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 134)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 135)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 136)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 137)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 138)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 139)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 140)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 141)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 142)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 143)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 144)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 145)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 146)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 147)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 148)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 149)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 150)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 151)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 152)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 153)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 154)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 155)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 156)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 157)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 158)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 159)) (i32.const 2))

    ;; J PIECE (type 5)
    (i32.store8 (i32.add (local.get $base) (i32.const 160)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 161)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 162)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 163)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 164)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 165)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 166)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 167)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 168)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 169)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 170)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 171)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 172)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 173)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 174)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 175)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 176)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 177)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 178)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 179)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 180)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 181)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 182)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 183)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 184)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 185)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 186)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 187)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 188)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 189)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 190)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 191)) (i32.const 2))

    ;; L PIECE (type 6)
    (i32.store8 (i32.add (local.get $base) (i32.const 192)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 193)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 194)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 195)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 196)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 197)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 198)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 199)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 200)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 201)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 202)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 203)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 204)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 205)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 206)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 207)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 208)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 209)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 210)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 211)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 212)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 213)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 214)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 215)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 216)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 217)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 218)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 219)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 220)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 221)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 222)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 223)) (i32.const 2))
  )

  ;; Get piece block X offset
  (func $get_piece_block_x (param $piece_type i32) (param $rotation i32) (param $block i32) (result i32)
    (i32.load8_u
      (i32.add
        (global.get $ADDR_PIECES)
        (i32.add
          (i32.add
            (i32.mul (local.get $piece_type) (i32.const 32))
            (i32.mul (local.get $rotation) (i32.const 8))
          )
          (i32.mul (local.get $block) (i32.const 2))
        )
      )
    )
  )

  ;; Get piece block Y offset
  (func $get_piece_block_y (param $piece_type i32) (param $rotation i32) (param $block i32) (result i32)
    (i32.load8_u
      (i32.add
        (global.get $ADDR_PIECES)
        (i32.add
          (i32.add
            (i32.add
              (i32.mul (local.get $piece_type) (i32.const 32))
              (i32.mul (local.get $rotation) (i32.const 8))
            )
            (i32.mul (local.get $block) (i32.const 2))
          )
          (i32.const 1)
        )
      )
    )
  )

  ;; ==========================================================================
  ;; COLLISION DETECTION
  ;; ==========================================================================

  (func $check_collision (param $piece_type i32) (param $x i32) (param $y i32) (param $rotation i32) (result i32)
    (local $block i32)
    (local $block_x i32)
    (local $block_y i32)
    (local $grid_x i32)
    (local $grid_y i32)
    
    (local.set $block (i32.const 0))
    (block $break
      (loop $check_loop
        (local.set $block_x (call $get_piece_block_x (local.get $piece_type) (local.get $rotation) (local.get $block)))
        (local.set $block_y (call $get_piece_block_y (local.get $piece_type) (local.get $rotation) (local.get $block)))
        (local.set $grid_x (i32.add (local.get $x) (local.get $block_x)))
        (local.set $grid_y (i32.add (local.get $y) (local.get $block_y)))
        
        (if (i32.lt_s (local.get $grid_x) (i32.const 0)) (then (return (i32.const 1))))
        (if (i32.ge_s (local.get $grid_x) (global.get $GRID_WIDTH)) (then (return (i32.const 1))))
        (if (i32.ge_s (local.get $grid_y) (global.get $GRID_HEIGHT)) (then (return (i32.const 1))))
        
        (if (i32.ge_s (local.get $grid_y) (i32.const 0))
          (then
            (if (i32.gt_s (call $get_grid (local.get $grid_x) (local.get $grid_y)) (i32.const 0))
              (then (return (i32.const 1)))
            )
          )
        )
        
        (local.set $block (i32.add (local.get $block) (i32.const 1)))
        (br_if $check_loop (i32.lt_s (local.get $block) (i32.const 4)))
      )
    )
    (i32.const 0)
  )

  ;; ==========================================================================
  ;; PIECE LOCKING AND LINE CLEARING
  ;; ==========================================================================

  (func $lock_piece
    (local $block i32)
    (local $block_x i32)
    (local $block_y i32)
    (local $grid_x i32)
    (local $grid_y i32)
    (local $piece_type i32)
    (local $piece_x i32)
    (local $piece_y i32)
    (local $piece_rot i32)
    
    (local.set $piece_type (i32.load (global.get $ADDR_PIECE_TYPE)))
    (local.set $piece_x (i32.load (global.get $ADDR_PIECE_X)))
    (local.set $piece_y (i32.load (global.get $ADDR_PIECE_Y)))
    (local.set $piece_rot (i32.load (global.get $ADDR_PIECE_ROT)))
    
    (local.set $block (i32.const 0))
    (block $break
      (loop $place_loop
        (local.set $block_x (call $get_piece_block_x (local.get $piece_type) (local.get $piece_rot) (local.get $block)))
        (local.set $block_y (call $get_piece_block_y (local.get $piece_type) (local.get $piece_rot) (local.get $block)))
        (local.set $grid_x (i32.add (local.get $piece_x) (local.get $block_x)))
        (local.set $grid_y (i32.add (local.get $piece_y) (local.get $block_y)))
        
        (if (i32.ge_s (local.get $grid_y) (i32.const 0))
          (then
            (call $set_grid (local.get $grid_x) (local.get $grid_y) 
              (i32.add (local.get $piece_type) (i32.const 1)))
          )
        )
        
        (local.set $block (i32.add (local.get $block) (i32.const 1)))
        (br_if $place_loop (i32.lt_s (local.get $block) (i32.const 4)))
      )
    )
  )

  (func $is_row_complete (param $row i32) (result i32)
    (local $col i32)
    (local.set $col (i32.const 0))
    (block $break
      (loop $check_loop
        (if (i32.eqz (call $get_grid (local.get $col) (local.get $row)))
          (then (return (i32.const 0)))
        )
        (local.set $col (i32.add (local.get $col) (i32.const 1)))
        (br_if $check_loop (i32.lt_s (local.get $col) (global.get $GRID_WIDTH)))
      )
    )
    (i32.const 1)
  )

  (func $clear_row (param $row i32)
    (local $r i32) (local $c i32)
    (local.set $r (local.get $row))
    (block $break
      (loop $shift_loop
        (if (i32.le_s (local.get $r) (i32.const 0)) (then (br $break)))
        (local.set $c (i32.const 0))
        (block $col_break
          (loop $col_loop
            (call $set_grid (local.get $c) (local.get $r)
              (call $get_grid (local.get $c) (i32.sub (local.get $r) (i32.const 1))))
            (local.set $c (i32.add (local.get $c) (i32.const 1)))
            (br_if $col_loop (i32.lt_s (local.get $c) (global.get $GRID_WIDTH)))
          )
        )
        (local.set $r (i32.sub (local.get $r) (i32.const 1)))
        (br $shift_loop)
      )
    )
    (local.set $c (i32.const 0))
    (block $top_break
      (loop $top_loop
        (call $set_grid (local.get $c) (i32.const 0) (i32.const 0))
        (local.set $c (i32.add (local.get $c) (i32.const 1)))
        (br_if $top_loop (i32.lt_s (local.get $c) (global.get $GRID_WIDTH)))
      )
    )
  )

  (func $clear_lines (result i32)
    (local $row i32)
    (local $lines_cleared i32)
    (local $score i32)
    (local $level i32)
    (local $total_lines i32)
    
    (local.set $lines_cleared (i32.const 0))
    (local.set $row (i32.sub (global.get $GRID_HEIGHT) (i32.const 1)))
    
    (block $break
      (loop $check_loop
        (if (i32.lt_s (local.get $row) (i32.const 0)) (then (br $break)))
        
        (if (call $is_row_complete (local.get $row))
          (then
            (call $clear_row (local.get $row))
            (local.set $lines_cleared (i32.add (local.get $lines_cleared) (i32.const 1)))
          )
          (else
            (local.set $row (i32.sub (local.get $row) (i32.const 1)))
          )
        )
        (br $check_loop)
      )
    )
    
    (if (i32.gt_s (local.get $lines_cleared) (i32.const 0))
      (then
        (local.set $level (i32.load (global.get $ADDR_LEVEL)))
        (local.set $score (i32.load (global.get $ADDR_SCORE)))
        
        (if (i32.eq (local.get $lines_cleared) (i32.const 1))
          (then (local.set $score (i32.add (local.get $score) (i32.mul (i32.const 100) (i32.add (local.get $level) (i32.const 1)))))))
        (if (i32.eq (local.get $lines_cleared) (i32.const 2))
          (then (local.set $score (i32.add (local.get $score) (i32.mul (i32.const 300) (i32.add (local.get $level) (i32.const 1)))))))
        (if (i32.eq (local.get $lines_cleared) (i32.const 3))
          (then (local.set $score (i32.add (local.get $score) (i32.mul (i32.const 500) (i32.add (local.get $level) (i32.const 1)))))))
        (if (i32.ge_s (local.get $lines_cleared) (i32.const 4))
          (then (local.set $score (i32.add (local.get $score) (i32.mul (i32.const 800) (i32.add (local.get $level) (i32.const 1)))))))
        
        (i32.store (global.get $ADDR_SCORE) (local.get $score))
        (local.set $total_lines (i32.add (i32.load (global.get $ADDR_LINES)) (local.get $lines_cleared)))
        (i32.store (global.get $ADDR_LINES) (local.get $total_lines))
        (i32.store (global.get $ADDR_LEVEL) (i32.div_u (local.get $total_lines) (i32.const 10)))
      )
    )
    (local.get $lines_cleared)
  )

  ;; ==========================================================================
  ;; PIECE SPAWNING
  ;; ==========================================================================

  (func $spawn_piece (result i32)
    (local $next_piece i32)
    (local.set $next_piece (i32.load (global.get $ADDR_NEXT_PIECE)))
    (i32.store (global.get $ADDR_PIECE_TYPE) (local.get $next_piece))
    (i32.store (global.get $ADDR_NEXT_PIECE) (call $random))
    (i32.store (global.get $ADDR_PIECE_X) (i32.const 3))
    (i32.store (global.get $ADDR_PIECE_Y) (i32.const 0))
    (i32.store (global.get $ADDR_PIECE_ROT) (i32.const 0))
    
    (if (result i32) (call $check_collision (local.get $next_piece) (i32.const 3) (i32.const 0) (i32.const 0))
      (then
        (i32.store (global.get $ADDR_GAME_OVER) (i32.const 1))
        (i32.const 0)
      )
      (else (i32.const 1))
    )
  )

  ;; ==========================================================================
  ;; RENDERING - All done in WASM!
  ;; ==========================================================================

  ;; Draw a single cell with 3D effect
  (func $draw_cell (param $gx i32) (param $gy i32) (param $color_type i32) (param $is_ghost i32)
    (local $px i32) (local $py i32)
    (local $color i32) (local $light i32) (local $dark i32)
    (local $size i32) (local $border i32)
    
    ;; Calculate pixel position (10px offset for border)
    (local.set $px (i32.add (i32.mul (local.get $gx) (global.get $CELL_SIZE)) (i32.const 10)))
    (local.set $py (i32.add (i32.mul (local.get $gy) (global.get $CELL_SIZE)) (i32.const 20)))
    (local.set $size (i32.sub (global.get $CELL_SIZE) (i32.const 2)))
    (local.set $border (i32.const 3))
    
    (local.set $color (call $get_piece_color (i32.sub (local.get $color_type) (i32.const 1))))
    
    (if (local.get $is_ghost)
      (then
        ;; Ghost piece - just draw outline
        (call $draw_hline (i32.add (local.get $px) (i32.const 1)) (i32.add (local.get $py) (i32.const 1)) (local.get $size) (local.get $color))
        (call $draw_hline (i32.add (local.get $px) (i32.const 1)) (i32.add (local.get $py) (local.get $size)) (local.get $size) (local.get $color))
        (call $draw_vline (i32.add (local.get $px) (i32.const 1)) (i32.add (local.get $py) (i32.const 1)) (local.get $size) (local.get $color))
        (call $draw_vline (i32.add (local.get $px) (local.get $size)) (i32.add (local.get $py) (i32.const 1)) (local.get $size) (local.get $color))
      )
      (else
        ;; Solid piece with 3D effect
        (local.set $light (call $lighten_color (local.get $color)))
        (local.set $dark (call $darken_color (local.get $color)))
        
        ;; Main body
        (call $fill_rect (i32.add (local.get $px) (i32.const 1)) (i32.add (local.get $py) (i32.const 1)) 
          (local.get $size) (local.get $size) (local.get $color))
        
        ;; Top highlight
        (call $fill_rect (i32.add (local.get $px) (i32.const 1)) (i32.add (local.get $py) (i32.const 1))
          (local.get $size) (local.get $border) (local.get $light))
        
        ;; Left highlight
        (call $fill_rect (i32.add (local.get $px) (i32.const 1)) (i32.add (local.get $py) (i32.const 1))
          (local.get $border) (local.get $size) (local.get $light))
        
        ;; Bottom shadow
        (call $fill_rect (i32.add (local.get $px) (i32.const 1)) 
          (i32.sub (i32.add (local.get $py) (local.get $size)) (i32.const 2))
          (local.get $size) (local.get $border) (local.get $dark))
        
        ;; Right shadow
        (call $fill_rect (i32.sub (i32.add (local.get $px) (local.get $size)) (i32.const 2))
          (i32.add (local.get $py) (i32.const 1))
          (local.get $border) (local.get $size) (local.get $dark))
      )
    )
  )

  ;; Calculate ghost Y position
  (func $get_ghost_y (result i32)
    (local $piece_type i32) (local $piece_x i32) (local $piece_y i32) (local $piece_rot i32)
    (local $ghost_y i32)
    
    (local.set $piece_type (i32.load (global.get $ADDR_PIECE_TYPE)))
    (local.set $piece_x (i32.load (global.get $ADDR_PIECE_X)))
    (local.set $piece_y (i32.load (global.get $ADDR_PIECE_Y)))
    (local.set $piece_rot (i32.load (global.get $ADDR_PIECE_ROT)))
    (local.set $ghost_y (local.get $piece_y))
    
    (block $break
      (loop $ghost_loop
        (if (i32.eqz (call $check_collision
            (local.get $piece_type) (local.get $piece_x)
            (i32.add (local.get $ghost_y) (i32.const 1)) (local.get $piece_rot)))
          (then
            (local.set $ghost_y (i32.add (local.get $ghost_y) (i32.const 1)))
            (br $ghost_loop)
          )
        )
      )
    )
    (local.get $ghost_y)
  )

  ;; Render entire frame to framebuffer
  (func $render
    (local $x i32) (local $y i32) (local $cell i32)
    (local $piece_type i32) (local $piece_x i32) (local $piece_y i32) (local $piece_rot i32)
    (local $ghost_y i32) (local $block i32)
    (local $block_x i32) (local $block_y i32)
    (local $grid_x i32) (local $grid_y i32)
    
    ;; Clear background
    (call $fill_rect (i32.const 0) (i32.const 0) (global.get $CANVAS_WIDTH) (global.get $CANVAS_HEIGHT) (global.get $COLOR_BG))
    
    ;; Draw grid background (slightly lighter)
    (call $fill_rect (i32.const 10) (i32.const 20) (i32.const 300) (i32.const 600) (i32.const 0xFF121212))
    
    ;; Draw grid lines
    (local.set $x (i32.const 0))
    (block $break_x
      (loop $loop_x
        (br_if $break_x (i32.gt_s (local.get $x) (global.get $GRID_WIDTH)))
        (call $draw_vline 
          (i32.add (i32.mul (local.get $x) (global.get $CELL_SIZE)) (i32.const 10))
          (i32.const 20)
          (i32.const 600)
          (global.get $COLOR_GRID))
        (local.set $x (i32.add (local.get $x) (i32.const 1)))
        (br $loop_x)
      )
    )
    
    (local.set $y (i32.const 0))
    (block $break_y
      (loop $loop_y
        (br_if $break_y (i32.gt_s (local.get $y) (global.get $GRID_HEIGHT)))
        (call $draw_hline
          (i32.const 10)
          (i32.add (i32.mul (local.get $y) (global.get $CELL_SIZE)) (i32.const 20))
          (i32.const 300)
          (global.get $COLOR_GRID))
        (local.set $y (i32.add (local.get $y) (i32.const 1)))
        (br $loop_y)
      )
    )
    
    ;; Draw locked pieces
    (local.set $y (i32.const 0))
    (block $break_grid_y
      (loop $loop_grid_y
        (br_if $break_grid_y (i32.ge_s (local.get $y) (global.get $GRID_HEIGHT)))
        (local.set $x (i32.const 0))
        (block $break_grid_x
          (loop $loop_grid_x
            (br_if $break_grid_x (i32.ge_s (local.get $x) (global.get $GRID_WIDTH)))
            (local.set $cell (call $get_grid (local.get $x) (local.get $y)))
            (if (i32.gt_s (local.get $cell) (i32.const 0))
              (then (call $draw_cell (local.get $x) (local.get $y) (local.get $cell) (i32.const 0)))
            )
            (local.set $x (i32.add (local.get $x) (i32.const 1)))
            (br $loop_grid_x)
          )
        )
        (local.set $y (i32.add (local.get $y) (i32.const 1)))
        (br $loop_grid_y)
      )
    )
    
    ;; Get current piece state
    (local.set $piece_type (i32.load (global.get $ADDR_PIECE_TYPE)))
    (local.set $piece_x (i32.load (global.get $ADDR_PIECE_X)))
    (local.set $piece_y (i32.load (global.get $ADDR_PIECE_Y)))
    (local.set $piece_rot (i32.load (global.get $ADDR_PIECE_ROT)))
    (local.set $ghost_y (call $get_ghost_y))
    
    ;; Draw ghost piece
    (if (i32.gt_s (local.get $ghost_y) (local.get $piece_y))
      (then
        (local.set $block (i32.const 0))
        (block $break_ghost
          (loop $loop_ghost
            (br_if $break_ghost (i32.ge_s (local.get $block) (i32.const 4)))
            (local.set $block_x (call $get_piece_block_x (local.get $piece_type) (local.get $piece_rot) (local.get $block)))
            (local.set $block_y (call $get_piece_block_y (local.get $piece_type) (local.get $piece_rot) (local.get $block)))
            (local.set $grid_x (i32.add (local.get $piece_x) (local.get $block_x)))
            (local.set $grid_y (i32.add (local.get $ghost_y) (local.get $block_y)))
            (if (i32.ge_s (local.get $grid_y) (i32.const 0))
              (then (call $draw_cell (local.get $grid_x) (local.get $grid_y) (i32.add (local.get $piece_type) (i32.const 1)) (i32.const 1)))
            )
            (local.set $block (i32.add (local.get $block) (i32.const 1)))
            (br $loop_ghost)
          )
        )
      )
    )
    
    ;; Draw current piece
    (local.set $block (i32.const 0))
    (block $break_piece
      (loop $loop_piece
        (br_if $break_piece (i32.ge_s (local.get $block) (i32.const 4)))
        (local.set $block_x (call $get_piece_block_x (local.get $piece_type) (local.get $piece_rot) (local.get $block)))
        (local.set $block_y (call $get_piece_block_y (local.get $piece_type) (local.get $piece_rot) (local.get $block)))
        (local.set $grid_x (i32.add (local.get $piece_x) (local.get $block_x)))
        (local.set $grid_y (i32.add (local.get $piece_y) (local.get $block_y)))
        (if (i32.ge_s (local.get $grid_y) (i32.const 0))
          (then (call $draw_cell (local.get $grid_x) (local.get $grid_y) (i32.add (local.get $piece_type) (i32.const 1)) (i32.const 0)))
        )
        (local.set $block (i32.add (local.get $block) (i32.const 1)))
        (br $loop_piece)
      )
    )
  )

  ;; ==========================================================================
  ;; EXPORTED FUNCTIONS
  ;; ==========================================================================

  ;; Initialize game
  (func (export "init") (param $seed i32)
    (local $i i32)
    (call $init_pieces)
    
    ;; Clear grid
    (local.set $i (i32.const 0))
    (block $break
      (loop $clear_loop
        (i32.store8 (local.get $i) (i32.const 0))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br_if $clear_loop (i32.lt_s (local.get $i) (global.get $GRID_SIZE)))
      )
    )
    
    ;; Initialize state
    (i32.store (global.get $ADDR_SCORE) (i32.const 0))
    (i32.store (global.get $ADDR_LEVEL) (i32.const 0))
    (i32.store (global.get $ADDR_LINES) (i32.const 0))
    (i32.store (global.get $ADDR_GAME_OVER) (i32.const 0))
    (i32.store (global.get $ADDR_DROP_TIMER) (i32.const 0))
    (i32.store (global.get $ADDR_FRAME_COUNT) (i32.const 0))
    (i32.store (global.get $ADDR_RANDOM_SEED) (local.get $seed))
    
    ;; Generate first pieces
    (i32.store (global.get $ADDR_NEXT_PIECE) (call $random))
    (drop (call $spawn_piece))
  )

  ;; Update game state - returns 1 if piece dropped
  (func (export "update") (result i32)
    (local $timer i32) (local $level i32) (local $drop_interval i32)
    
    (if (i32.load (global.get $ADDR_GAME_OVER)) (then (return (i32.const 0))))
    
    ;; Calculate drop speed based on level
    (local.set $level (i32.load (global.get $ADDR_LEVEL)))
    (local.set $drop_interval (i32.sub (i32.const 60) (i32.mul (local.get $level) (i32.const 6))))
    (if (i32.lt_s (local.get $drop_interval) (i32.const 6))
      (then (local.set $drop_interval (i32.const 6))))
    
    ;; Update timer
    (local.set $timer (i32.add (i32.load (global.get $ADDR_DROP_TIMER)) (i32.const 1)))
    
    (if (result i32) (i32.ge_s (local.get $timer) (local.get $drop_interval))
      (then
        (i32.store (global.get $ADDR_DROP_TIMER) (i32.const 0))
        (drop (call $soft_drop))
        (i32.const 1)
      )
      (else
        (i32.store (global.get $ADDR_DROP_TIMER) (local.get $timer))
        (i32.const 0)
      )
    )
  )

  ;; Render frame to framebuffer
  (func (export "render")
    (call $render)
  )

  ;; Input handlers
  (func (export "move_left") (result i32)
    (local $piece_type i32) (local $piece_x i32) (local $piece_y i32) (local $piece_rot i32)
    (local.set $piece_type (i32.load (global.get $ADDR_PIECE_TYPE)))
    (local.set $piece_x (i32.load (global.get $ADDR_PIECE_X)))
    (local.set $piece_y (i32.load (global.get $ADDR_PIECE_Y)))
    (local.set $piece_rot (i32.load (global.get $ADDR_PIECE_ROT)))
    
    (if (result i32) (i32.eqz (call $check_collision
        (local.get $piece_type) (i32.sub (local.get $piece_x) (i32.const 1))
        (local.get $piece_y) (local.get $piece_rot)))
      (then
        (i32.store (global.get $ADDR_PIECE_X) (i32.sub (local.get $piece_x) (i32.const 1)))
        (i32.const 1)
      )
      (else (i32.const 0))
    )
  )

  (func (export "move_right") (result i32)
    (local $piece_type i32) (local $piece_x i32) (local $piece_y i32) (local $piece_rot i32)
    (local.set $piece_type (i32.load (global.get $ADDR_PIECE_TYPE)))
    (local.set $piece_x (i32.load (global.get $ADDR_PIECE_X)))
    (local.set $piece_y (i32.load (global.get $ADDR_PIECE_Y)))
    (local.set $piece_rot (i32.load (global.get $ADDR_PIECE_ROT)))
    
    (if (result i32) (i32.eqz (call $check_collision
        (local.get $piece_type) (i32.add (local.get $piece_x) (i32.const 1))
        (local.get $piece_y) (local.get $piece_rot)))
      (then
        (i32.store (global.get $ADDR_PIECE_X) (i32.add (local.get $piece_x) (i32.const 1)))
        (i32.const 1)
      )
      (else (i32.const 0))
    )
  )

  (func (export "rotate") (result i32)
    (local $piece_type i32) (local $piece_x i32) (local $piece_y i32) (local $piece_rot i32)
    (local $new_rot i32)
    
    (local.set $piece_type (i32.load (global.get $ADDR_PIECE_TYPE)))
    (local.set $piece_x (i32.load (global.get $ADDR_PIECE_X)))
    (local.set $piece_y (i32.load (global.get $ADDR_PIECE_Y)))
    (local.set $piece_rot (i32.load (global.get $ADDR_PIECE_ROT)))
    (local.set $new_rot (i32.rem_u (i32.add (local.get $piece_rot) (i32.const 1)) (i32.const 4)))
    
    (if (result i32) (i32.eqz (call $check_collision
        (local.get $piece_type) (local.get $piece_x) (local.get $piece_y) (local.get $new_rot)))
      (then
        (i32.store (global.get $ADDR_PIECE_ROT) (local.get $new_rot))
        (i32.const 1)
      )
      (else
        ;; Wall kick left
        (if (result i32) (i32.eqz (call $check_collision
            (local.get $piece_type) (i32.sub (local.get $piece_x) (i32.const 1))
            (local.get $piece_y) (local.get $new_rot)))
          (then
            (i32.store (global.get $ADDR_PIECE_X) (i32.sub (local.get $piece_x) (i32.const 1)))
            (i32.store (global.get $ADDR_PIECE_ROT) (local.get $new_rot))
            (i32.const 1)
          )
          (else
            ;; Wall kick right
            (if (result i32) (i32.eqz (call $check_collision
                (local.get $piece_type) (i32.add (local.get $piece_x) (i32.const 1))
                (local.get $piece_y) (local.get $new_rot)))
              (then
                (i32.store (global.get $ADDR_PIECE_X) (i32.add (local.get $piece_x) (i32.const 1)))
                (i32.store (global.get $ADDR_PIECE_ROT) (local.get $new_rot))
                (i32.const 1)
              )
              (else (i32.const 0))
            )
          )
        )
      )
    )
  )

  (func $soft_drop (export "soft_drop") (result i32)
    (local $piece_type i32) (local $piece_x i32) (local $piece_y i32) (local $piece_rot i32)
    
    (local.set $piece_type (i32.load (global.get $ADDR_PIECE_TYPE)))
    (local.set $piece_x (i32.load (global.get $ADDR_PIECE_X)))
    (local.set $piece_y (i32.load (global.get $ADDR_PIECE_Y)))
    (local.set $piece_rot (i32.load (global.get $ADDR_PIECE_ROT)))
    
    (if (result i32) (i32.eqz (call $check_collision
        (local.get $piece_type) (local.get $piece_x)
        (i32.add (local.get $piece_y) (i32.const 1)) (local.get $piece_rot)))
      (then
        (i32.store (global.get $ADDR_PIECE_Y) (i32.add (local.get $piece_y) (i32.const 1)))
        (i32.const 1)
      )
      (else
        (call $lock_piece)
        (drop (call $clear_lines))
        (drop (call $spawn_piece))
        (i32.const 0)
      )
    )
  )

  (func (export "hard_drop") (result i32)
    (local $piece_type i32) (local $piece_x i32) (local $piece_y i32) (local $piece_rot i32)
    (local $rows_dropped i32)
    
    (local.set $piece_type (i32.load (global.get $ADDR_PIECE_TYPE)))
    (local.set $piece_x (i32.load (global.get $ADDR_PIECE_X)))
    (local.set $piece_y (i32.load (global.get $ADDR_PIECE_Y)))
    (local.set $piece_rot (i32.load (global.get $ADDR_PIECE_ROT)))
    (local.set $rows_dropped (i32.const 0))
    
    (block $break
      (loop $drop_loop
        (if (i32.eqz (call $check_collision
            (local.get $piece_type) (local.get $piece_x)
            (i32.add (local.get $piece_y) (i32.const 1)) (local.get $piece_rot)))
          (then
            (local.set $piece_y (i32.add (local.get $piece_y) (i32.const 1)))
            (local.set $rows_dropped (i32.add (local.get $rows_dropped) (i32.const 1)))
            (br $drop_loop)
          )
        )
      )
    )
    
    (i32.store (global.get $ADDR_PIECE_Y) (local.get $piece_y))
    (i32.store (global.get $ADDR_SCORE)
      (i32.add (i32.load (global.get $ADDR_SCORE)) (i32.mul (local.get $rows_dropped) (i32.const 2))))
    
    (call $lock_piece)
    (drop (call $clear_lines))
    (drop (call $spawn_piece))
    (local.get $rows_dropped)
  )

  ;; Getters for UI
  (func (export "get_score") (result i32) (i32.load (global.get $ADDR_SCORE)))
  (func (export "get_level") (result i32) (i32.load (global.get $ADDR_LEVEL)))
  (func (export "get_lines") (result i32) (i32.load (global.get $ADDR_LINES)))
  (func (export "is_game_over") (result i32) (i32.load (global.get $ADDR_GAME_OVER)))
  (func (export "get_next_piece") (result i32) (i32.load (global.get $ADDR_NEXT_PIECE)))
  
  ;; Framebuffer info for JS
  (func (export "get_framebuffer_offset") (result i32) (global.get $FRAMEBUFFER_OFFSET))
  (func (export "get_canvas_width") (result i32) (global.get $CANVAS_WIDTH))
  (func (export "get_canvas_height") (result i32) (global.get $CANVAS_HEIGHT))
)
