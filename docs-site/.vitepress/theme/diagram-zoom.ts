// Mermaid 图「放大镜」查看器：页面内图已缩放适配列宽（不横向滚动），超宽图
// 缩放后字偏小 —— 点图进入本查看器看原尺寸，可滚轮缩放、拖拽平移。
// 文档站只在 runtime 生效：enhanceApp 首次调用时挂一次委托监听。

const OVERLAY_ID = 'pb-diagram-zoom'

interface ViewState {
  scale: number
  x: number
  y: number
}

function closeOverlay() {
  document.getElementById(OVERLAY_ID)?.remove()
  document.removeEventListener('keydown', onKeydown)
}

function onKeydown(e: KeyboardEvent) {
  if (e.key === 'Escape') closeOverlay()
}

function applyTransform(stage: HTMLElement, svg: SVGElement, v: ViewState) {
  svg.style.transform = `translate(${v.x}px, ${v.y}px) scale(${v.scale})`
  svg.style.transformOrigin = '0 0'
  stage.scrollLeft = 0
  stage.scrollTop = 0
}

function openOverlay(svg: SVGElement) {
  closeOverlay()

  const vb = (svg.getAttribute('viewBox') || '').split(/\s+/).map(Number)
  const naturalW = vb.length === 4 && vb[2] > 0 ? vb[2] : svg.clientWidth
  const naturalH = vb.length === 4 && vb[3] > 0 ? vb[3] : svg.clientHeight

  const clone = svg.cloneNode(true) as SVGElement
  clone.removeAttribute('style')
  clone.setAttribute('width', String(naturalW))
  clone.setAttribute('height', String(naturalH))
  clone.style.maxWidth = 'none'
  clone.style.width = `${naturalW}px`
  clone.style.height = `${naturalH}px`

  const overlay = document.createElement('div')
  overlay.id = OVERLAY_ID
  overlay.className = 'pb-zoom-overlay'

  // ---- 工具条 ----
  const bar = document.createElement('div')
  bar.className = 'pb-zoom-bar'

  const makeBtn = (label: string, title: string, onClick: () => void) => {
    const b = document.createElement('button')
    b.type = 'button'
    b.className = 'pb-zoom-btn'
    b.textContent = label
    b.title = title
    b.addEventListener('click', onClick)
    return b
  }

  const stage = document.createElement('div')
  stage.className = 'pb-zoom-stage'

  const state: ViewState = { scale: 1, x: 0, y: 0 }
  const apply = () => applyTransform(stage, clone, state)

  const zoomBy = (factor: number, cx?: number, cy?: number) => {
    const next = Math.min(4, Math.max(0.1, state.scale * factor))
    const rect = stage.getBoundingClientRect()
    const px = cx ?? rect.width / 2
    const py = cy ?? rect.height / 2
    // 以 (px,py) 为锚点缩放
    state.x = px - ((px - state.x) * next) / state.scale
    state.y = py - ((py - state.y) * next) / state.scale
    state.scale = next
    apply()
    zoomLabel.textContent = `${Math.round(next * 100)}%`
  }

  const fitWidth = () => {
    const rect = stage.getBoundingClientRect()
    state.scale = Math.min(1, (rect.width - 48) / naturalW)
    state.x = (rect.width - naturalW * state.scale) / 2
    state.y = 16
    apply()
    zoomLabel.textContent = `${Math.round(state.scale * 100)}%`
  }

  const zoomLabel = document.createElement('span')
  zoomLabel.className = 'pb-zoom-level'
  zoomLabel.textContent = '100%'

  bar.appendChild(makeBtn('−', '缩小', () => zoomBy(1 / 1.25)))
  bar.appendChild(makeBtn('+', '放大', () => zoomBy(1.25)))
  bar.appendChild(zoomLabel)
  bar.appendChild(makeBtn('适应宽度', '缩放到刚好铺满窗口宽度', fitWidth))
  bar.appendChild(makeBtn('1:1', '原始尺寸', () => {
    state.scale = 1
    state.x = 16
    state.y = 16
    apply()
    zoomLabel.textContent = '100%'
  }))

  const hint = document.createElement('span')
  hint.className = 'pb-zoom-hint'
  hint.textContent = '滚轮缩放 · 拖拽平移 · Esc 关闭'

  const closeBtn = makeBtn('✕', '关闭', closeOverlay)
  closeBtn.classList.add('pb-zoom-btn--close')

  bar.appendChild(hint)
  bar.appendChild(closeBtn)

  stage.appendChild(clone)

  overlay.appendChild(bar)
  overlay.appendChild(stage)
  overlay.addEventListener('click', (e) => {
    if (e.target === overlay || e.target === stage) closeOverlay()
  })

  // 滚轮缩放（以光标为锚点）
  stage.addEventListener('wheel', (e) => {
    e.preventDefault()
    const rect = stage.getBoundingClientRect()
    zoomBy(e.deltaY < 0 ? 1.12 : 1 / 1.12, e.clientX - rect.left, e.clientY - rect.top)
  }, { passive: false })

  // 拖拽平移
  let dragging = false
  let startX = 0
  let startY = 0
  let originX = 0
  let originY = 0
  stage.addEventListener('mousedown', (e) => {
    dragging = true
    startX = e.clientX
    startY = e.clientY
    originX = state.x
    originY = state.y
    stage.classList.add('is-dragging')
  })
  window.addEventListener('mousemove', (e) => {
    if (!dragging) return
    state.x = originX + (e.clientX - startX)
    state.y = originY + (e.clientY - startY)
    apply()
  })
  window.addEventListener('mouseup', () => {
    dragging = false
    stage.classList.remove('is-dragging')
  })

  document.body.appendChild(overlay)
  document.addEventListener('keydown', onKeydown)
  fitWidth()
}

/** 挂一次全站委托：点到 .mermaid 内的 svg 就开放大镜 */
export function installDiagramZoom() {
  // enhanceApp 在 SSR 构建期也会跑，那儿没有 document
  if (typeof document === 'undefined') return
  document.addEventListener('click', (e) => {
    const target = e.target as HTMLElement | null
    if (!target || !target.closest) return
    const svg = target.closest('.mermaid svg') as SVGElement | null
    if (!svg) return
    e.preventDefault()
    openOverlay(svg)
  })
}
