/**
 * WASM Tetris - Minimal JavaScript Bridge
 * 
 * This is the ABSOLUTE MINIMUM JavaScript required.
 * WebAssembly cannot directly access:
 * - DOM (Canvas, HTML elements)
 * - Browser events (keyboard, mouse)
 * - requestAnimationFrame
 * 
 * ALL game logic, rendering, colors, and physics are in WASM.
 * JS only: loads WASM, copies framebuffer to canvas, forwards key events.
 */

let wasm, memory, canvas, ctx, imageData;

// Load WASM and start
async function main() {
  // Load and instantiate WASM module
  const response = await fetch('tetris.wasm');
  const bytes = await response.arrayBuffer();
  const { instance } = await WebAssembly.instantiate(bytes);
  wasm = instance.exports;
  memory = new Uint8Array(wasm.memory.buffer);
  
  // Setup canvas
  canvas = document.getElementById('game');
  ctx = canvas.getContext('2d');
  canvas.width = wasm.get_canvas_width();
  canvas.height = wasm.get_canvas_height();
  imageData = ctx.createImageData(canvas.width, canvas.height);
  
  // Initialize game with random seed
  wasm.init(Date.now() & 0x7FFFFFFF);
  
  // Input handling - just forward to WASM
  document.addEventListener('keydown', e => {
    if (wasm.is_game_over()) {
      if (e.key === ' ' || e.key === 'Enter') {
        wasm.init(Date.now() & 0x7FFFFFFF);
      }
      return;
    }
    switch(e.key) {
      case 'ArrowLeft': case 'a': wasm.move_left(); break;
      case 'ArrowRight': case 'd': wasm.move_right(); break;
      case 'ArrowUp': case 'w': wasm.rotate(); break;
      case 'ArrowDown': case 's': wasm.soft_drop(); break;
      case ' ': wasm.hard_drop(); break;
    }
    e.preventDefault();
  });
  
  // Game loop
  function loop() {
    wasm.update();           // WASM updates game state
    wasm.render();           // WASM renders to framebuffer
    
    // Copy WASM framebuffer to canvas
    const fb = wasm.get_framebuffer_offset();
    imageData.data.set(memory.subarray(fb, fb + canvas.width * canvas.height * 4));
    ctx.putImageData(imageData, 0, 0);
    
    // Draw UI overlay (score, level, etc.)
    drawUI();
    
    requestAnimationFrame(loop);
  }
  loop();
}

// Simple UI overlay (could also be done in WASM with font rendering)
function drawUI() {
  ctx.font = 'bold 16px monospace';
  ctx.fillStyle = '#00ffff';
  ctx.fillText(`SCORE: ${wasm.get_score()}`, 10, 16);
  ctx.fillText(`LEVEL: ${wasm.get_level()}`, 200, 16);
  ctx.fillText(`LINES: ${wasm.get_lines()}`, 120, 16);
  
  if (wasm.is_game_over()) {
    ctx.fillStyle = 'rgba(0,0,0,0.7)';
    ctx.fillRect(0, 250, 320, 100);
    ctx.font = 'bold 32px monospace';
    ctx.fillStyle = '#ff0066';
    ctx.fillText('GAME OVER', 70, 300);
    ctx.font = '16px monospace';
    ctx.fillStyle = '#00ffff';
    ctx.fillText('Press SPACE to restart', 70, 330);
  }
}

main();
