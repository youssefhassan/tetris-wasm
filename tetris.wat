;; =============================================================================
;; TETRIS GAME - WebAssembly Text Format (WAT)
;; =============================================================================
;; 
;; Memory Layout (linear memory):
;; -----------------------------------------------------------------------------
;; Offset 0-199:     Grid cells (10 columns x 20 rows = 200 bytes)
;;                   Each byte: 0 = empty, 1-7 = piece type color
;;                   Grid[row][col] = memory[row * 10 + col]
;;                   Row 0 is TOP, Row 19 is BOTTOM
;;
;; Offset 200-203:   Current piece type (i32) - 0-6 for I,O,T,S,Z,J,L
;; Offset 204-207:   Current piece X position (i32) - column of piece origin
;; Offset 208-211:   Current piece Y position (i32) - row of piece origin
;; Offset 212-215:   Current piece rotation (i32) - 0-3 for 4 orientations
;; Offset 216-219:   Score (i32)
;; Offset 220-223:   Level (i32)
;; Offset 224-227:   Lines cleared (i32)
;; Offset 228-231:   Game over flag (i32) - 0 = playing, 1 = game over
;; Offset 232-235:   Next piece type (i32)
;; Offset 236-239:   Drop timer (i32) - frames until auto-drop
;; Offset 240-243:   Random seed (i32) - for piece generation
;;
;; Offset 300-427:   Piece definitions (4 pieces x 4 rotations x 4 blocks x 2 coords)
;;                   Each piece: 4 blocks, each block has (x,y) offset from origin
;;
;; =============================================================================

(module
  ;; Import memory so JS can read game state
  (memory (export "memory") 1)

  ;; ==========================================================================
  ;; CONSTANTS
  ;; ==========================================================================
  (global $GRID_WIDTH i32 (i32.const 10))
  (global $GRID_HEIGHT i32 (i32.const 20))
  (global $GRID_SIZE i32 (i32.const 200))
  
  ;; Memory offsets
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
  
  ;; Piece definitions base address
  (global $ADDR_PIECES i32 (i32.const 300))

  ;; ==========================================================================
  ;; HELPER FUNCTIONS
  ;; ==========================================================================

  ;; Get grid cell value at (x, y)
  ;; Returns: cell value (0 = empty, 1-7 = piece type)
  (func $get_grid (param $x i32) (param $y i32) (result i32)
    ;; Check bounds
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
      (then
        ;; Out of bounds - treat as solid (for collision)
        (i32.const 1)
      )
      (else
        ;; In bounds - read from memory
        (i32.load8_u
          (i32.add
            (i32.mul (local.get $y) (global.get $GRID_WIDTH))
            (local.get $x)
          )
        )
      )
    )
  )

  ;; Set grid cell value at (x, y)
  (func $set_grid (param $x i32) (param $y i32) (param $value i32)
    ;; Only set if in bounds
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

  ;; Simple pseudo-random number generator (Linear Congruential Generator)
  ;; Returns: random number 0-6 (for piece selection)
  (func $random (result i32)
    (local $seed i32)
    ;; seed = (seed * 1103515245 + 12345) & 0x7fffffff
    (local.set $seed
      (i32.and
        (i32.add
          (i32.mul
            (i32.load (global.get $ADDR_RANDOM_SEED))
            (i32.const 1103515245)
          )
          (i32.const 12345)
        )
        (i32.const 0x7fffffff)
      )
    )
    (i32.store (global.get $ADDR_RANDOM_SEED) (local.get $seed))
    ;; Return seed % 7
    (i32.rem_u (local.get $seed) (i32.const 7))
  )

  ;; ==========================================================================
  ;; PIECE DEFINITIONS
  ;; ==========================================================================
  ;; Each piece has 4 rotations, each rotation has 4 blocks
  ;; Block offsets are stored as (x, y) pairs relative to piece origin
  
  ;; Initialize piece shape data in memory
  ;; Piece data format: [x0,y0, x1,y1, x2,y2, x3,y3] for each rotation
  ;; Total: 7 pieces * 4 rotations * 4 blocks * 2 coords = 224 bytes
  
  (func $init_pieces
    (local $base i32)
    (local.set $base (global.get $ADDR_PIECES))
    
    ;; ========== I PIECE (type 0) ==========
    ;; Rotation 0: horizontal  ####
    (i32.store8 (i32.add (local.get $base) (i32.const 0)) (i32.const 0))   ;; x0
    (i32.store8 (i32.add (local.get $base) (i32.const 1)) (i32.const 0))   ;; y0
    (i32.store8 (i32.add (local.get $base) (i32.const 2)) (i32.const 1))   ;; x1
    (i32.store8 (i32.add (local.get $base) (i32.const 3)) (i32.const 0))   ;; y1
    (i32.store8 (i32.add (local.get $base) (i32.const 4)) (i32.const 2))   ;; x2
    (i32.store8 (i32.add (local.get $base) (i32.const 5)) (i32.const 0))   ;; y2
    (i32.store8 (i32.add (local.get $base) (i32.const 6)) (i32.const 3))   ;; x3
    (i32.store8 (i32.add (local.get $base) (i32.const 7)) (i32.const 0))   ;; y3
    
    ;; Rotation 1: vertical
    (i32.store8 (i32.add (local.get $base) (i32.const 8)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 9)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 10)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 11)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 12)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 13)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 14)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 15)) (i32.const 3))
    
    ;; Rotation 2: same as 0
    (i32.store8 (i32.add (local.get $base) (i32.const 16)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 17)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 18)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 19)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 20)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 21)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 22)) (i32.const 3))
    (i32.store8 (i32.add (local.get $base) (i32.const 23)) (i32.const 0))
    
    ;; Rotation 3: same as 1
    (i32.store8 (i32.add (local.get $base) (i32.const 24)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 25)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 26)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 27)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 28)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 29)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 30)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 31)) (i32.const 3))
    
    ;; ========== O PIECE (type 1) ==========
    ;; All rotations same:  ##
    ;;                      ##
    ;; Rotation 0
    (i32.store8 (i32.add (local.get $base) (i32.const 32)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 33)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 34)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 35)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 36)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 37)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 38)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 39)) (i32.const 1))
    ;; Rotation 1 (same)
    (i32.store8 (i32.add (local.get $base) (i32.const 40)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 41)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 42)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 43)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 44)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 45)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 46)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 47)) (i32.const 1))
    ;; Rotation 2 (same)
    (i32.store8 (i32.add (local.get $base) (i32.const 48)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 49)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 50)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 51)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 52)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 53)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 54)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 55)) (i32.const 1))
    ;; Rotation 3 (same)
    (i32.store8 (i32.add (local.get $base) (i32.const 56)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 57)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 58)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 59)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 60)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 61)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 62)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 63)) (i32.const 1))
    
    ;; ========== T PIECE (type 2) ==========
    ;; Rotation 0:  ###
    ;;               #
    (i32.store8 (i32.add (local.get $base) (i32.const 64)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 65)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 66)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 67)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 68)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 69)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 70)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 71)) (i32.const 1))
    ;; Rotation 1:  #
    ;;              ##
    ;;              #
    (i32.store8 (i32.add (local.get $base) (i32.const 72)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 73)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 74)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 75)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 76)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 77)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 78)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 79)) (i32.const 2))
    ;; Rotation 2:   #
    ;;              ###
    (i32.store8 (i32.add (local.get $base) (i32.const 80)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 81)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 82)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 83)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 84)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 85)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 86)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 87)) (i32.const 1))
    ;; Rotation 3:  #
    ;;              ##
    ;;               #
    (i32.store8 (i32.add (local.get $base) (i32.const 88)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 89)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 90)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 91)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 92)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 93)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 94)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 95)) (i32.const 2))
    
    ;; ========== S PIECE (type 3) ==========
    ;; Rotation 0:   ##
    ;;              ##
    (i32.store8 (i32.add (local.get $base) (i32.const 96)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 97)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 98)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 99)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 100)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 101)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 102)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 103)) (i32.const 1))
    ;; Rotation 1:  #
    ;;              ##
    ;;               #
    (i32.store8 (i32.add (local.get $base) (i32.const 104)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 105)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 106)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 107)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 108)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 109)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 110)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 111)) (i32.const 2))
    ;; Rotation 2: same as 0
    (i32.store8 (i32.add (local.get $base) (i32.const 112)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 113)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 114)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 115)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 116)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 117)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 118)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 119)) (i32.const 1))
    ;; Rotation 3: same as 1
    (i32.store8 (i32.add (local.get $base) (i32.const 120)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 121)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 122)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 123)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 124)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 125)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 126)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 127)) (i32.const 2))
    
    ;; ========== Z PIECE (type 4) ==========
    ;; Rotation 0:  ##
    ;;               ##
    (i32.store8 (i32.add (local.get $base) (i32.const 128)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 129)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 130)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 131)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 132)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 133)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 134)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 135)) (i32.const 1))
    ;; Rotation 1:   #
    ;;              ##
    ;;              #
    (i32.store8 (i32.add (local.get $base) (i32.const 136)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 137)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 138)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 139)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 140)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 141)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 142)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 143)) (i32.const 2))
    ;; Rotation 2: same as 0
    (i32.store8 (i32.add (local.get $base) (i32.const 144)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 145)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 146)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 147)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 148)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 149)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 150)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 151)) (i32.const 1))
    ;; Rotation 3: same as 1
    (i32.store8 (i32.add (local.get $base) (i32.const 152)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 153)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 154)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 155)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 156)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 157)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 158)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 159)) (i32.const 2))
    
    ;; ========== J PIECE (type 5) ==========
    ;; Rotation 0:  #
    ;;              ###
    (i32.store8 (i32.add (local.get $base) (i32.const 160)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 161)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 162)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 163)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 164)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 165)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 166)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 167)) (i32.const 1))
    ;; Rotation 1:  ##
    ;;              #
    ;;              #
    (i32.store8 (i32.add (local.get $base) (i32.const 168)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 169)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 170)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 171)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 172)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 173)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 174)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 175)) (i32.const 2))
    ;; Rotation 2:  ###
    ;;                #
    (i32.store8 (i32.add (local.get $base) (i32.const 176)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 177)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 178)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 179)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 180)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 181)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 182)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 183)) (i32.const 1))
    ;; Rotation 3:   #
    ;;               #
    ;;              ##
    (i32.store8 (i32.add (local.get $base) (i32.const 184)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 185)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 186)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 187)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 188)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 189)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 190)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 191)) (i32.const 2))
    
    ;; ========== L PIECE (type 6) ==========
    ;; Rotation 0:    #
    ;;              ###
    (i32.store8 (i32.add (local.get $base) (i32.const 192)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 193)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 194)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 195)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 196)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 197)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 198)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 199)) (i32.const 1))
    ;; Rotation 1:  #
    ;;              #
    ;;              ##
    (i32.store8 (i32.add (local.get $base) (i32.const 200)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 201)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 202)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 203)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 204)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 205)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 206)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 207)) (i32.const 2))
    ;; Rotation 2:  ###
    ;;              #
    (i32.store8 (i32.add (local.get $base) (i32.const 208)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 209)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 210)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 211)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 212)) (i32.const 2))
    (i32.store8 (i32.add (local.get $base) (i32.const 213)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 214)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 215)) (i32.const 1))
    ;; Rotation 3:  ##
    ;;               #
    ;;               #
    (i32.store8 (i32.add (local.get $base) (i32.const 216)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 217)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 218)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 219)) (i32.const 0))
    (i32.store8 (i32.add (local.get $base) (i32.const 220)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 221)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 222)) (i32.const 1))
    (i32.store8 (i32.add (local.get $base) (i32.const 223)) (i32.const 2))
  )

  ;; Get block position from piece definition
  ;; Returns x offset for block index (0-3) of piece type and rotation
  (func $get_piece_block_x (param $piece_type i32) (param $rotation i32) (param $block i32) (result i32)
    (i32.load8_u
      (i32.add
        (global.get $ADDR_PIECES)
        (i32.add
          (i32.add
            (i32.mul (local.get $piece_type) (i32.const 32))  ;; 32 bytes per piece type
            (i32.mul (local.get $rotation) (i32.const 8))     ;; 8 bytes per rotation
          )
          (i32.mul (local.get $block) (i32.const 2))          ;; 2 bytes per block (x,y)
        )
      )
    )
  )

  ;; Get y offset for block
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
          (i32.const 1)  ;; +1 for y coordinate
        )
      )
    )
  )

  ;; ==========================================================================
  ;; COLLISION DETECTION
  ;; ==========================================================================

  ;; Check if piece at given position would collide
  ;; Returns: 1 if collision, 0 if no collision
  (func $check_collision (param $piece_type i32) (param $x i32) (param $y i32) (param $rotation i32) (result i32)
    (local $block i32)
    (local $block_x i32)
    (local $block_y i32)
    (local $grid_x i32)
    (local $grid_y i32)
    
    ;; Check all 4 blocks of the piece
    (local.set $block (i32.const 0))
    (block $break
      (loop $check_loop
        ;; Get block position
        (local.set $block_x (call $get_piece_block_x (local.get $piece_type) (local.get $rotation) (local.get $block)))
        (local.set $block_y (call $get_piece_block_y (local.get $piece_type) (local.get $rotation) (local.get $block)))
        
        ;; Calculate grid position
        (local.set $grid_x (i32.add (local.get $x) (local.get $block_x)))
        (local.set $grid_y (i32.add (local.get $y) (local.get $block_y)))
        
        ;; Check left/right bounds
        (if (i32.lt_s (local.get $grid_x) (i32.const 0))
          (then (return (i32.const 1)))
        )
        (if (i32.ge_s (local.get $grid_x) (global.get $GRID_WIDTH))
          (then (return (i32.const 1)))
        )
        
        ;; Check bottom bound
        (if (i32.ge_s (local.get $grid_y) (global.get $GRID_HEIGHT))
          (then (return (i32.const 1)))
        )
        
        ;; Check collision with placed pieces (only if in valid grid area)
        (if (i32.ge_s (local.get $grid_y) (i32.const 0))
          (then
            (if (i32.gt_s (call $get_grid (local.get $grid_x) (local.get $grid_y)) (i32.const 0))
              (then (return (i32.const 1)))
            )
          )
        )
        
        ;; Next block
        (local.set $block (i32.add (local.get $block) (i32.const 1)))
        (br_if $check_loop (i32.lt_s (local.get $block) (i32.const 4)))
      )
    )
    
    ;; No collision
    (i32.const 0)
  )

  ;; ==========================================================================
  ;; PIECE LOCKING AND LINE CLEARING
  ;; ==========================================================================

  ;; Lock current piece into the grid
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
    
    ;; Load current piece state
    (local.set $piece_type (i32.load (global.get $ADDR_PIECE_TYPE)))
    (local.set $piece_x (i32.load (global.get $ADDR_PIECE_X)))
    (local.set $piece_y (i32.load (global.get $ADDR_PIECE_Y)))
    (local.set $piece_rot (i32.load (global.get $ADDR_PIECE_ROT)))
    
    ;; Place all 4 blocks
    (local.set $block (i32.const 0))
    (block $break
      (loop $place_loop
        (local.set $block_x (call $get_piece_block_x (local.get $piece_type) (local.get $piece_rot) (local.get $block)))
        (local.set $block_y (call $get_piece_block_y (local.get $piece_type) (local.get $piece_rot) (local.get $block)))
        
        (local.set $grid_x (i32.add (local.get $piece_x) (local.get $block_x)))
        (local.set $grid_y (i32.add (local.get $piece_y) (local.get $block_y)))
        
        ;; Set grid cell (piece_type + 1 for color, since 0 = empty)
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

  ;; Check if a row is complete (all cells filled)
  (func $is_row_complete (param $row i32) (result i32)
    (local $col i32)
    
    (local.set $col (i32.const 0))
    (block $break
      (loop $check_loop
        (if (i32.eqz (call $get_grid (local.get $col) (local.get $row)))
          (then (return (i32.const 0)))  ;; Empty cell found, row not complete
        )
        (local.set $col (i32.add (local.get $col) (i32.const 1)))
        (br_if $check_loop (i32.lt_s (local.get $col) (global.get $GRID_WIDTH)))
      )
    )
    (i32.const 1)  ;; Row is complete
  )

  ;; Clear a row and shift everything above down
  (func $clear_row (param $row i32)
    (local $r i32)
    (local $c i32)
    
    ;; Shift all rows above down by one
    (local.set $r (local.get $row))
    (block $break
      (loop $shift_loop
        (if (i32.le_s (local.get $r) (i32.const 0))
          (then (br $break))
        )
        
        ;; Copy row above to current row
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
    
    ;; Clear top row
    (local.set $c (i32.const 0))
    (block $top_break
      (loop $top_loop
        (call $set_grid (local.get $c) (i32.const 0) (i32.const 0))
        (local.set $c (i32.add (local.get $c) (i32.const 1)))
        (br_if $top_loop (i32.lt_s (local.get $c) (global.get $GRID_WIDTH)))
      )
    )
  )

  ;; Clear completed lines and update score
  ;; Returns: number of lines cleared
  (func $clear_lines (result i32)
    (local $row i32)
    (local $lines_cleared i32)
    (local $score i32)
    (local $level i32)
    (local $total_lines i32)
    
    (local.set $lines_cleared (i32.const 0))
    (local.set $row (i32.sub (global.get $GRID_HEIGHT) (i32.const 1)))
    
    ;; Check from bottom to top
    (block $break
      (loop $check_loop
        (if (i32.lt_s (local.get $row) (i32.const 0))
          (then (br $break))
        )
        
        (if (call $is_row_complete (local.get $row))
          (then
            (call $clear_row (local.get $row))
            (local.set $lines_cleared (i32.add (local.get $lines_cleared) (i32.const 1)))
            ;; Don't decrement row, check same row again (shifted down)
          )
          (else
            (local.set $row (i32.sub (local.get $row) (i32.const 1)))
          )
        )
        
        (br $check_loop)
      )
    )
    
    ;; Update score based on lines cleared
    ;; Scoring: 1 line = 100, 2 = 300, 3 = 500, 4 = 800 (Tetris!)
    (if (i32.gt_s (local.get $lines_cleared) (i32.const 0))
      (then
        (local.set $level (i32.load (global.get $ADDR_LEVEL)))
        (local.set $score (i32.load (global.get $ADDR_SCORE)))
        
        ;; Score multiplier based on lines cleared
        (if (i32.eq (local.get $lines_cleared) (i32.const 1))
          (then (local.set $score (i32.add (local.get $score) (i32.mul (i32.const 100) (i32.add (local.get $level) (i32.const 1))))))
        )
        (if (i32.eq (local.get $lines_cleared) (i32.const 2))
          (then (local.set $score (i32.add (local.get $score) (i32.mul (i32.const 300) (i32.add (local.get $level) (i32.const 1))))))
        )
        (if (i32.eq (local.get $lines_cleared) (i32.const 3))
          (then (local.set $score (i32.add (local.get $score) (i32.mul (i32.const 500) (i32.add (local.get $level) (i32.const 1))))))
        )
        (if (i32.ge_s (local.get $lines_cleared) (i32.const 4))
          (then (local.set $score (i32.add (local.get $score) (i32.mul (i32.const 800) (i32.add (local.get $level) (i32.const 1))))))
        )
        
        (i32.store (global.get $ADDR_SCORE) (local.get $score))
        
        ;; Update total lines and level
        (local.set $total_lines (i32.add (i32.load (global.get $ADDR_LINES)) (local.get $lines_cleared)))
        (i32.store (global.get $ADDR_LINES) (local.get $total_lines))
        
        ;; Level up every 10 lines
        (i32.store (global.get $ADDR_LEVEL) (i32.div_u (local.get $total_lines) (i32.const 10)))
      )
    )
    
    (local.get $lines_cleared)
  )

  ;; ==========================================================================
  ;; PIECE SPAWNING
  ;; ==========================================================================

  ;; Spawn a new piece at the top
  ;; Returns: 1 if successful, 0 if game over (collision on spawn)
  (func $spawn_piece (result i32)
    (local $next_piece i32)
    
    ;; Use next piece as current piece
    (local.set $next_piece (i32.load (global.get $ADDR_NEXT_PIECE)))
    (i32.store (global.get $ADDR_PIECE_TYPE) (local.get $next_piece))
    
    ;; Generate new next piece
    (i32.store (global.get $ADDR_NEXT_PIECE) (call $random))
    
    ;; Set starting position (centered at top)
    (i32.store (global.get $ADDR_PIECE_X) (i32.const 3))
    (i32.store (global.get $ADDR_PIECE_Y) (i32.const 0))
    (i32.store (global.get $ADDR_PIECE_ROT) (i32.const 0))
    
    ;; Check for collision (game over condition)
    (if (result i32) (call $check_collision 
        (local.get $next_piece)
        (i32.const 3)
        (i32.const 0)
        (i32.const 0))
      (then
        ;; Game over!
        (i32.store (global.get $ADDR_GAME_OVER) (i32.const 1))
        (i32.const 0)
      )
      (else
        (i32.const 1)
      )
    )
  )

  ;; ==========================================================================
  ;; EXPORTED FUNCTIONS
  ;; ==========================================================================

  ;; Initialize the game
  (func (export "init_game") (param $seed i32)
    (local $i i32)
    
    ;; Initialize piece definitions
    (call $init_pieces)
    
    ;; Clear the grid
    (local.set $i (i32.const 0))
    (block $break
      (loop $clear_loop
        (i32.store8 (local.get $i) (i32.const 0))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br_if $clear_loop (i32.lt_s (local.get $i) (global.get $GRID_SIZE)))
      )
    )
    
    ;; Initialize game state
    (i32.store (global.get $ADDR_SCORE) (i32.const 0))
    (i32.store (global.get $ADDR_LEVEL) (i32.const 0))
    (i32.store (global.get $ADDR_LINES) (i32.const 0))
    (i32.store (global.get $ADDR_GAME_OVER) (i32.const 0))
    (i32.store (global.get $ADDR_DROP_TIMER) (i32.const 0))
    
    ;; Set random seed
    (i32.store (global.get $ADDR_RANDOM_SEED) (local.get $seed))
    
    ;; Generate first piece
    (i32.store (global.get $ADDR_NEXT_PIECE) (call $random))
    (drop (call $spawn_piece))
  )

  ;; Get grid cell value (for rendering)
  (func (export "get_grid_cell") (param $x i32) (param $y i32) (result i32)
    (if (result i32)
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
        (i32.load8_u
          (i32.add
            (i32.mul (local.get $y) (global.get $GRID_WIDTH))
            (local.get $x)
          )
        )
      )
      (else
        (i32.const 0)
      )
    )
  )

  ;; Get current piece type
  (func (export "get_piece_type") (result i32)
    (i32.load (global.get $ADDR_PIECE_TYPE))
  )

  ;; Get current piece X position
  (func (export "get_piece_x") (result i32)
    (i32.load (global.get $ADDR_PIECE_X))
  )

  ;; Get current piece Y position
  (func (export "get_piece_y") (result i32)
    (i32.load (global.get $ADDR_PIECE_Y))
  )

  ;; Get current piece rotation
  (func (export "get_piece_rotation") (result i32)
    (i32.load (global.get $ADDR_PIECE_ROT))
  )

  ;; Get block X offset for current piece
  (func (export "get_current_block_x") (param $block i32) (result i32)
    (call $get_piece_block_x
      (i32.load (global.get $ADDR_PIECE_TYPE))
      (i32.load (global.get $ADDR_PIECE_ROT))
      (local.get $block)
    )
  )

  ;; Get block Y offset for current piece
  (func (export "get_current_block_y") (param $block i32) (result i32)
    (call $get_piece_block_y
      (i32.load (global.get $ADDR_PIECE_TYPE))
      (i32.load (global.get $ADDR_PIECE_ROT))
      (local.get $block)
    )
  )

  ;; Get next piece type
  (func (export "get_next_piece") (result i32)
    (i32.load (global.get $ADDR_NEXT_PIECE))
  )

  ;; Get block position for any piece type (for preview)
  (func (export "get_piece_block_x") (param $piece_type i32) (param $rotation i32) (param $block i32) (result i32)
    (call $get_piece_block_x (local.get $piece_type) (local.get $rotation) (local.get $block))
  )

  (func (export "get_piece_block_y") (param $piece_type i32) (param $rotation i32) (param $block i32) (result i32)
    (call $get_piece_block_y (local.get $piece_type) (local.get $rotation) (local.get $block))
  )

  ;; Get score
  (func (export "get_score") (result i32)
    (i32.load (global.get $ADDR_SCORE))
  )

  ;; Get level
  (func (export "get_level") (result i32)
    (i32.load (global.get $ADDR_LEVEL))
  )

  ;; Get lines cleared
  (func (export "get_lines") (result i32)
    (i32.load (global.get $ADDR_LINES))
  )

  ;; Check if game is over
  (func (export "is_game_over") (result i32)
    (i32.load (global.get $ADDR_GAME_OVER))
  )

  ;; Move piece left
  ;; Returns: 1 if moved, 0 if blocked
  (func (export "move_left") (result i32)
    (local $piece_type i32)
    (local $piece_x i32)
    (local $piece_y i32)
    (local $piece_rot i32)
    
    (local.set $piece_type (i32.load (global.get $ADDR_PIECE_TYPE)))
    (local.set $piece_x (i32.load (global.get $ADDR_PIECE_X)))
    (local.set $piece_y (i32.load (global.get $ADDR_PIECE_Y)))
    (local.set $piece_rot (i32.load (global.get $ADDR_PIECE_ROT)))
    
    (if (result i32) (i32.eqz (call $check_collision
        (local.get $piece_type)
        (i32.sub (local.get $piece_x) (i32.const 1))
        (local.get $piece_y)
        (local.get $piece_rot)))
      (then
        (i32.store (global.get $ADDR_PIECE_X) (i32.sub (local.get $piece_x) (i32.const 1)))
        (i32.const 1)
      )
      (else
        (i32.const 0)
      )
    )
  )

  ;; Move piece right
  ;; Returns: 1 if moved, 0 if blocked
  (func (export "move_right") (result i32)
    (local $piece_type i32)
    (local $piece_x i32)
    (local $piece_y i32)
    (local $piece_rot i32)
    
    (local.set $piece_type (i32.load (global.get $ADDR_PIECE_TYPE)))
    (local.set $piece_x (i32.load (global.get $ADDR_PIECE_X)))
    (local.set $piece_y (i32.load (global.get $ADDR_PIECE_Y)))
    (local.set $piece_rot (i32.load (global.get $ADDR_PIECE_ROT)))
    
    (if (result i32) (i32.eqz (call $check_collision
        (local.get $piece_type)
        (i32.add (local.get $piece_x) (i32.const 1))
        (local.get $piece_y)
        (local.get $piece_rot)))
      (then
        (i32.store (global.get $ADDR_PIECE_X) (i32.add (local.get $piece_x) (i32.const 1)))
        (i32.const 1)
      )
      (else
        (i32.const 0)
      )
    )
  )

  ;; Rotate piece clockwise
  ;; Returns: 1 if rotated, 0 if blocked
  (func (export "rotate") (result i32)
    (local $piece_type i32)
    (local $piece_x i32)
    (local $piece_y i32)
    (local $piece_rot i32)
    (local $new_rot i32)
    
    (local.set $piece_type (i32.load (global.get $ADDR_PIECE_TYPE)))
    (local.set $piece_x (i32.load (global.get $ADDR_PIECE_X)))
    (local.set $piece_y (i32.load (global.get $ADDR_PIECE_Y)))
    (local.set $piece_rot (i32.load (global.get $ADDR_PIECE_ROT)))
    
    ;; New rotation = (current + 1) % 4
    (local.set $new_rot (i32.rem_u (i32.add (local.get $piece_rot) (i32.const 1)) (i32.const 4)))
    
    (if (result i32) (i32.eqz (call $check_collision
        (local.get $piece_type)
        (local.get $piece_x)
        (local.get $piece_y)
        (local.get $new_rot)))
      (then
        (i32.store (global.get $ADDR_PIECE_ROT) (local.get $new_rot))
        (i32.const 1)
      )
      (else
        ;; Try wall kick - move left
        (if (result i32) (i32.eqz (call $check_collision
            (local.get $piece_type)
            (i32.sub (local.get $piece_x) (i32.const 1))
            (local.get $piece_y)
            (local.get $new_rot)))
          (then
            (i32.store (global.get $ADDR_PIECE_X) (i32.sub (local.get $piece_x) (i32.const 1)))
            (i32.store (global.get $ADDR_PIECE_ROT) (local.get $new_rot))
            (i32.const 1)
          )
          (else
            ;; Try wall kick - move right
            (if (result i32) (i32.eqz (call $check_collision
                (local.get $piece_type)
                (i32.add (local.get $piece_x) (i32.const 1))
                (local.get $piece_y)
                (local.get $new_rot)))
              (then
                (i32.store (global.get $ADDR_PIECE_X) (i32.add (local.get $piece_x) (i32.const 1)))
                (i32.store (global.get $ADDR_PIECE_ROT) (local.get $new_rot))
                (i32.const 1)
              )
              (else
                (i32.const 0)
              )
            )
          )
        )
      )
    )
  )

  ;; Soft drop - move piece down one row
  ;; Returns: 1 if moved, 0 if landed (piece locked)
  (func $soft_drop (export "soft_drop") (result i32)
    (local $piece_type i32)
    (local $piece_x i32)
    (local $piece_y i32)
    (local $piece_rot i32)
    
    (local.set $piece_type (i32.load (global.get $ADDR_PIECE_TYPE)))
    (local.set $piece_x (i32.load (global.get $ADDR_PIECE_X)))
    (local.set $piece_y (i32.load (global.get $ADDR_PIECE_Y)))
    (local.set $piece_rot (i32.load (global.get $ADDR_PIECE_ROT)))
    
    (if (result i32) (i32.eqz (call $check_collision
        (local.get $piece_type)
        (local.get $piece_x)
        (i32.add (local.get $piece_y) (i32.const 1))
        (local.get $piece_rot)))
      (then
        ;; Can move down
        (i32.store (global.get $ADDR_PIECE_Y) (i32.add (local.get $piece_y) (i32.const 1)))
        (i32.const 1)
      )
      (else
        ;; Can't move down - lock piece
        (call $lock_piece)
        (drop (call $clear_lines))
        (drop (call $spawn_piece))
        (i32.const 0)
      )
    )
  )

  ;; Hard drop - drop piece to bottom instantly
  ;; Returns: number of rows dropped
  (func (export "hard_drop") (result i32)
    (local $piece_type i32)
    (local $piece_x i32)
    (local $piece_y i32)
    (local $piece_rot i32)
    (local $rows_dropped i32)
    
    (local.set $piece_type (i32.load (global.get $ADDR_PIECE_TYPE)))
    (local.set $piece_x (i32.load (global.get $ADDR_PIECE_X)))
    (local.set $piece_y (i32.load (global.get $ADDR_PIECE_Y)))
    (local.set $piece_rot (i32.load (global.get $ADDR_PIECE_ROT)))
    (local.set $rows_dropped (i32.const 0))
    
    ;; Move down until collision
    (block $break
      (loop $drop_loop
        (if (i32.eqz (call $check_collision
            (local.get $piece_type)
            (local.get $piece_x)
            (i32.add (local.get $piece_y) (i32.const 1))
            (local.get $piece_rot)))
          (then
            (local.set $piece_y (i32.add (local.get $piece_y) (i32.const 1)))
            (local.set $rows_dropped (i32.add (local.get $rows_dropped) (i32.const 1)))
            (br $drop_loop)
          )
        )
      )
    )
    
    ;; Update position and lock
    (i32.store (global.get $ADDR_PIECE_Y) (local.get $piece_y))
    
    ;; Add score for hard drop (2 points per row)
    (i32.store (global.get $ADDR_SCORE)
      (i32.add
        (i32.load (global.get $ADDR_SCORE))
        (i32.mul (local.get $rows_dropped) (i32.const 2))
      )
    )
    
    (call $lock_piece)
    (drop (call $clear_lines))
    (drop (call $spawn_piece))
    
    (local.get $rows_dropped)
  )

  ;; Update game state (called each frame)
  ;; Returns: 1 if piece dropped naturally this frame, 0 otherwise
  (func (export "update") (result i32)
    (local $timer i32)
    (local $level i32)
    (local $drop_interval i32)
    
    ;; Don't update if game over
    (if (i32.load (global.get $ADDR_GAME_OVER))
      (then (return (i32.const 0)))
    )
    
    ;; Calculate drop interval based on level
    ;; Level 0: 60 frames, Level 1: 54, Level 2: 48, etc.
    ;; Minimum: 6 frames
    (local.set $level (i32.load (global.get $ADDR_LEVEL)))
    (local.set $drop_interval
      (i32.sub (i32.const 60) (i32.mul (local.get $level) (i32.const 6)))
    )
    (if (i32.lt_s (local.get $drop_interval) (i32.const 6))
      (then (local.set $drop_interval (i32.const 6)))
    )
    
    ;; Increment timer
    (local.set $timer (i32.add (i32.load (global.get $ADDR_DROP_TIMER)) (i32.const 1)))
    
    ;; Check if it's time to drop
    (if (result i32) (i32.ge_s (local.get $timer) (local.get $drop_interval))
      (then
        ;; Reset timer
        (i32.store (global.get $ADDR_DROP_TIMER) (i32.const 0))
        ;; Drop the piece
        (drop (call $soft_drop))
        (i32.const 1)
      )
      (else
        ;; Just update timer
        (i32.store (global.get $ADDR_DROP_TIMER) (local.get $timer))
        (i32.const 0)
      )
    )
  )

  ;; Get ghost piece Y position (where piece would land)
  (func (export "get_ghost_y") (result i32)
    (local $piece_type i32)
    (local $piece_x i32)
    (local $piece_y i32)
    (local $piece_rot i32)
    (local $ghost_y i32)
    
    (local.set $piece_type (i32.load (global.get $ADDR_PIECE_TYPE)))
    (local.set $piece_x (i32.load (global.get $ADDR_PIECE_X)))
    (local.set $piece_y (i32.load (global.get $ADDR_PIECE_Y)))
    (local.set $piece_rot (i32.load (global.get $ADDR_PIECE_ROT)))
    (local.set $ghost_y (local.get $piece_y))
    
    ;; Move ghost down until collision
    (block $break
      (loop $ghost_loop
        (if (i32.eqz (call $check_collision
            (local.get $piece_type)
            (local.get $piece_x)
            (i32.add (local.get $ghost_y) (i32.const 1))
            (local.get $piece_rot)))
          (then
            (local.set $ghost_y (i32.add (local.get $ghost_y) (i32.const 1)))
            (br $ghost_loop)
          )
        )
      )
    )
    
    (local.get $ghost_y)
  )
)
