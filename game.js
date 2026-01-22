/**
 * WASM Tetris - JavaScript Game Controller
 * 
 * This file handles:
 * - Loading and instantiating the WebAssembly module
 * - Rendering the game state to canvas
 * - Handling keyboard/touch input
 * - Managing the game loop timing
 */

// =============================================================================
// CONFIGURATION
// =============================================================================

const CONFIG = {
  // Grid dimensions
  GRID_WIDTH: 10,
  GRID_HEIGHT: 20,
  
  // Cell size in pixels
  CELL_SIZE: 30,
  
  // Colors for each piece type (index 1-7, 0 is empty)
  PIECE_COLORS: [
    null,                    // 0: empty
    '#00f5ff',              // 1: I - cyan
    '#ffea00',              // 2: O - yellow
    '#d000ff',              // 3: T - purple
    '#00ff6a',              // 4: S - green
    '#ff3366',              // 5: Z - red
    '#3366ff',              // 6: J - blue
    '#ff9500',              // 7: L - orange
  ],
  
  // Darker versions for 3D effect
  PIECE_COLORS_DARK: [
    null,
    '#009999',              // I
    '#998c00',              // O
    '#7a0099',              // T
    '#009940',              // S
    '#991f3d',              // Z
    '#1f3d99',              // J
    '#995900',              // L
  ],
  
  // Lighter versions for highlights
  PIECE_COLORS_LIGHT: [
    null,
    '#66ffff',              // I
    '#ffffaa',              // O
    '#e066ff',              // T
    '#66ff99',              // S
    '#ff6699',              // Z
    '#6699ff',              // J
    '#ffaa66',              // L
  ],
  
  // Ghost piece opacity
  GHOST_OPACITY: 0.25,
  
  // Grid styling
  GRID_LINE_COLOR: 'rgba(255, 255, 255, 0.05)',
  GRID_BG_COLOR: '#0a0a0f',
  
  // Game timing (60 FPS target)
  FRAME_RATE: 60,
  
  // Key repeat settings (in milliseconds)
  KEY_REPEAT_DELAY: 170,    // Initial delay before repeat starts
  KEY_REPEAT_RATE: 50,      // Rate of repeat once started
};

// =============================================================================
// GAME STATE
// =============================================================================

let wasm = null;
let gameCanvas, gameCtx;
let nextCanvas, nextCtx;
let animationFrameId = null;
let lastTime = 0;
let frameAccumulator = 0;
const FRAME_TIME = 1000 / CONFIG.FRAME_RATE;

// Input state
const keysPressed = {};
const keyRepeatTimers = {};

// Line clear animation
let lineClearAnimation = null;

// =============================================================================
// WASM LOADING
// =============================================================================

async function loadWasm() {
  try {
    // Fetch and compile the WASM binary
    const response = await fetch('tetris.wasm');
    const bytes = await response.arrayBuffer();
    const { instance } = await WebAssembly.instantiate(bytes, {});
    
    wasm = instance.exports;
    console.log('WASM module loaded successfully!');
    console.log('Exported functions:', Object.keys(wasm));
    
    return true;
  } catch (error) {
    console.error('Failed to load WASM module:', error);
    return false;
  }
}

// =============================================================================
// RENDERING
// =============================================================================

/**
 * Draw a single cell with 3D-like effect
 */
function drawCell(ctx, x, y, colorIndex, isGhost = false) {
  if (colorIndex === 0) return;
  
  const px = x * CONFIG.CELL_SIZE;
  const py = y * CONFIG.CELL_SIZE;
  const size = CONFIG.CELL_SIZE;
  const padding = 1;
  
  const color = CONFIG.PIECE_COLORS[colorIndex];
  const colorDark = CONFIG.PIECE_COLORS_DARK[colorIndex];
  const colorLight = CONFIG.PIECE_COLORS_LIGHT[colorIndex];
  
  if (isGhost) {
    // Ghost piece - just outline
    ctx.strokeStyle = color;
    ctx.globalAlpha = CONFIG.GHOST_OPACITY;
    ctx.lineWidth = 2;
    ctx.strokeRect(px + padding + 2, py + padding + 2, size - padding * 2 - 4, size - padding * 2 - 4);
    ctx.globalAlpha = 1;
    return;
  }
  
  // Main cell body
  ctx.fillStyle = color;
  ctx.fillRect(px + padding, py + padding, size - padding * 2, size - padding * 2);
  
  // Top and left highlight (lighter)
  ctx.fillStyle = colorLight;
  // Top edge
  ctx.fillRect(px + padding, py + padding, size - padding * 2, 3);
  // Left edge
  ctx.fillRect(px + padding, py + padding, 3, size - padding * 2);
  
  // Bottom and right shadow (darker)
  ctx.fillStyle = colorDark;
  // Bottom edge
  ctx.fillRect(px + padding, py + size - padding - 3, size - padding * 2, 3);
  // Right edge
  ctx.fillRect(px + size - padding - 3, py + padding, 3, size - padding * 2);
  
  // Inner glow
  ctx.fillStyle = 'rgba(255, 255, 255, 0.1)';
  ctx.fillRect(px + 6, py + 6, size - 12, size - 12);
}

/**
 * Draw the game grid with all locked pieces
 */
function drawGrid() {
  // Clear canvas
  gameCtx.fillStyle = CONFIG.GRID_BG_COLOR;
  gameCtx.fillRect(0, 0, gameCanvas.width, gameCanvas.height);
  
  // Draw grid lines
  gameCtx.strokeStyle = CONFIG.GRID_LINE_COLOR;
  gameCtx.lineWidth = 1;
  
  for (let x = 0; x <= CONFIG.GRID_WIDTH; x++) {
    gameCtx.beginPath();
    gameCtx.moveTo(x * CONFIG.CELL_SIZE, 0);
    gameCtx.lineTo(x * CONFIG.CELL_SIZE, gameCanvas.height);
    gameCtx.stroke();
  }
  
  for (let y = 0; y <= CONFIG.GRID_HEIGHT; y++) {
    gameCtx.beginPath();
    gameCtx.moveTo(0, y * CONFIG.CELL_SIZE);
    gameCtx.lineTo(gameCanvas.width, y * CONFIG.CELL_SIZE);
    gameCtx.stroke();
  }
  
  // Draw locked pieces from grid
  for (let y = 0; y < CONFIG.GRID_HEIGHT; y++) {
    for (let x = 0; x < CONFIG.GRID_WIDTH; x++) {
      const cell = wasm.get_grid_cell(x, y);
      if (cell > 0) {
        drawCell(gameCtx, x, y, cell);
      }
    }
  }
}

/**
 * Draw the current falling piece and its ghost
 */
function drawCurrentPiece() {
  const pieceType = wasm.get_piece_type();
  const pieceX = wasm.get_piece_x();
  const pieceY = wasm.get_piece_y();
  const ghostY = wasm.get_ghost_y();
  
  // Draw ghost piece first (so it's behind the real piece)
  if (ghostY > pieceY) {
    for (let block = 0; block < 4; block++) {
      const blockX = wasm.get_current_block_x(block);
      const blockY = wasm.get_current_block_y(block);
      const gridX = pieceX + blockX;
      const gridY = ghostY + blockY;
      
      if (gridY >= 0) {
        drawCell(gameCtx, gridX, gridY, pieceType + 1, true);
      }
    }
  }
  
  // Draw the actual piece
  for (let block = 0; block < 4; block++) {
    const blockX = wasm.get_current_block_x(block);
    const blockY = wasm.get_current_block_y(block);
    const gridX = pieceX + blockX;
    const gridY = pieceY + blockY;
    
    if (gridY >= 0) {
      drawCell(gameCtx, gridX, gridY, pieceType + 1);
    }
  }
}

/**
 * Draw the next piece preview
 */
function drawNextPiece() {
  // Clear preview canvas
  nextCtx.fillStyle = 'rgba(0, 0, 0, 0.3)';
  nextCtx.fillRect(0, 0, nextCanvas.width, nextCanvas.height);
  
  const nextPiece = wasm.get_next_piece();
  const previewCellSize = 20;
  
  // Calculate center offset
  const offsetX = (nextCanvas.width - previewCellSize * 4) / 2;
  const offsetY = (nextCanvas.height - previewCellSize * 2) / 2;
  
  // Draw the piece
  for (let block = 0; block < 4; block++) {
    const blockX = wasm.get_piece_block_x(nextPiece, 0, block);
    const blockY = wasm.get_piece_block_y(nextPiece, 0, block);
    
    const px = offsetX + blockX * previewCellSize;
    const py = offsetY + blockY * previewCellSize;
    
    const color = CONFIG.PIECE_COLORS[nextPiece + 1];
    const colorDark = CONFIG.PIECE_COLORS_DARK[nextPiece + 1];
    const colorLight = CONFIG.PIECE_COLORS_LIGHT[nextPiece + 1];
    
    // Draw cell
    nextCtx.fillStyle = color;
    nextCtx.fillRect(px + 1, py + 1, previewCellSize - 2, previewCellSize - 2);
    
    // Highlights
    nextCtx.fillStyle = colorLight;
    nextCtx.fillRect(px + 1, py + 1, previewCellSize - 2, 2);
    nextCtx.fillRect(px + 1, py + 1, 2, previewCellSize - 2);
    
    // Shadows
    nextCtx.fillStyle = colorDark;
    nextCtx.fillRect(px + 1, py + previewCellSize - 3, previewCellSize - 2, 2);
    nextCtx.fillRect(px + previewCellSize - 3, py + 1, 2, previewCellSize - 2);
  }
}

/**
 * Update the score/level/lines display
 */
function updateStats() {
  document.getElementById('scoreDisplay').textContent = wasm.get_score().toLocaleString();
  document.getElementById('levelDisplay').textContent = wasm.get_level();
  document.getElementById('linesDisplay').textContent = wasm.get_lines();
}

/**
 * Render the complete game frame
 */
function render() {
  drawGrid();
  drawCurrentPiece();
  drawNextPiece();
  updateStats();
}

// =============================================================================
// INPUT HANDLING
// =============================================================================

/**
 * Process a single key action
 */
function processKey(key) {
  if (wasm.is_game_over()) return;
  
  switch (key) {
    case 'ArrowLeft':
    case 'a':
    case 'A':
      wasm.move_left();
      break;
      
    case 'ArrowRight':
    case 'd':
    case 'D':
      wasm.move_right();
      break;
      
    case 'ArrowUp':
    case 'w':
    case 'W':
      wasm.rotate();
      break;
      
    case 'ArrowDown':
    case 's':
    case 'S':
      wasm.soft_drop();
      break;
      
    case ' ':
      wasm.hard_drop();
      break;
  }
}

/**
 * Start key repeat for held keys
 */
function startKeyRepeat(key) {
  // Only repeat movement keys
  if (!['ArrowLeft', 'ArrowRight', 'ArrowDown', 'a', 'A', 'd', 'D', 's', 'S'].includes(key)) {
    return;
  }
  
  // Initial delay before repeat starts
  keyRepeatTimers[key] = setTimeout(() => {
    // Repeat at fixed interval
    keyRepeatTimers[key] = setInterval(() => {
      if (keysPressed[key]) {
        processKey(key);
      }
    }, CONFIG.KEY_REPEAT_RATE);
  }, CONFIG.KEY_REPEAT_DELAY);
}

/**
 * Stop key repeat
 */
function stopKeyRepeat(key) {
  if (keyRepeatTimers[key]) {
    clearTimeout(keyRepeatTimers[key]);
    clearInterval(keyRepeatTimers[key]);
    delete keyRepeatTimers[key];
  }
}

/**
 * Handle keydown events
 */
function handleKeyDown(event) {
  // Prevent default for game keys
  if (['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', ' '].includes(event.key)) {
    event.preventDefault();
  }
  
  // Ignore if already pressed (prevents key repeat from OS)
  if (keysPressed[event.key]) return;
  
  keysPressed[event.key] = true;
  processKey(event.key);
  startKeyRepeat(event.key);
}

/**
 * Handle keyup events
 */
function handleKeyUp(event) {
  keysPressed[event.key] = false;
  stopKeyRepeat(event.key);
}

/**
 * Setup touch controls for mobile
 */
function setupTouchControls() {
  const btnLeft = document.getElementById('btnLeft');
  const btnRight = document.getElementById('btnRight');
  const btnRotate = document.getElementById('btnRotate');
  const btnDrop = document.getElementById('btnDrop');
  const btnHardDrop = document.getElementById('btnHardDrop');
  
  // Helper to handle both touch and click
  function addTouchHandler(btn, action) {
    let repeatTimer = null;
    
    const startAction = (e) => {
      e.preventDefault();
      action();
      // Start repeat for movement buttons
      if (btn === btnLeft || btn === btnRight || btn === btnDrop) {
        repeatTimer = setInterval(action, CONFIG.KEY_REPEAT_RATE);
      }
    };
    
    const stopAction = (e) => {
      e.preventDefault();
      if (repeatTimer) {
        clearInterval(repeatTimer);
        repeatTimer = null;
      }
    };
    
    btn.addEventListener('touchstart', startAction);
    btn.addEventListener('touchend', stopAction);
    btn.addEventListener('touchcancel', stopAction);
    btn.addEventListener('mousedown', startAction);
    btn.addEventListener('mouseup', stopAction);
    btn.addEventListener('mouseleave', stopAction);
  }
  
  addTouchHandler(btnLeft, () => {
    if (!wasm.is_game_over()) wasm.move_left();
  });
  
  addTouchHandler(btnRight, () => {
    if (!wasm.is_game_over()) wasm.move_right();
  });
  
  addTouchHandler(btnRotate, () => {
    if (!wasm.is_game_over()) wasm.rotate();
  });
  
  addTouchHandler(btnDrop, () => {
    if (!wasm.is_game_over()) wasm.soft_drop();
  });
  
  addTouchHandler(btnHardDrop, () => {
    if (!wasm.is_game_over()) wasm.hard_drop();
  });
}

// =============================================================================
// GAME LOOP
// =============================================================================

/**
 * Main game loop
 */
function gameLoop(currentTime) {
  animationFrameId = requestAnimationFrame(gameLoop);
  
  // Calculate delta time
  const deltaTime = currentTime - lastTime;
  lastTime = currentTime;
  
  // Accumulate time
  frameAccumulator += deltaTime;
  
  // Fixed timestep updates
  while (frameAccumulator >= FRAME_TIME) {
    // Update game state
    wasm.update();
    
    // Check for game over
    if (wasm.is_game_over()) {
      showGameOver();
    }
    
    frameAccumulator -= FRAME_TIME;
  }
  
  // Render
  render();
}

/**
 * Start the game
 */
function startGame() {
  // Initialize WASM game with random seed
  const seed = Date.now() % 0x7fffffff;
  wasm.init_game(seed);
  
  // Hide game over overlay
  document.getElementById('gameOverOverlay').classList.remove('visible');
  
  // Start game loop
  lastTime = performance.now();
  frameAccumulator = 0;
  
  if (animationFrameId) {
    cancelAnimationFrame(animationFrameId);
  }
  animationFrameId = requestAnimationFrame(gameLoop);
}

/**
 * Show game over screen
 */
function showGameOver() {
  document.getElementById('finalScore').textContent = wasm.get_score().toLocaleString();
  document.getElementById('gameOverOverlay').classList.add('visible');
}

// =============================================================================
// INITIALIZATION
// =============================================================================

async function init() {
  // Get canvas elements
  gameCanvas = document.getElementById('gameCanvas');
  gameCtx = gameCanvas.getContext('2d');
  nextCanvas = document.getElementById('nextPieceCanvas');
  nextCtx = nextCanvas.getContext('2d');
  
  // Setup input
  document.addEventListener('keydown', handleKeyDown);
  document.addEventListener('keyup', handleKeyUp);
  
  // Setup touch controls
  setupTouchControls();
  
  // Setup restart button
  document.getElementById('restartBtn').addEventListener('click', startGame);
  
  // Load WASM and start game
  const loaded = await loadWasm();
  if (loaded) {
    startGame();
  } else {
    alert('Failed to load game. Make sure tetris.wasm exists.');
  }
}

// Start when DOM is ready
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init);
} else {
  init();
}
