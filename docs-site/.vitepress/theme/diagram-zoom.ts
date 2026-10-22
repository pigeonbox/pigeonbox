// Mermaid 图「点击放大」：页面内图已缩放适配列宽（不横向滚动），但超宽图
// 缩放后字偏小 —— 点击图进入全屏查看原尺寸（矢量，放大依然清晰）。
// 文档站只在 runtime 生效：enhanceApp 首次调用时挂一次委托监听。
const OVERLAY_ID = 'pb-diagram-zoom'

function closeOverlay() {
  document.getElementById(OVERLAY_ID)?.remove()
  document.removeEventListener('keydown', onKeydown)
}

function onKeydown(e: KeyboardEvent) {
  if (e.key === 'Escape') closeOverlay()
}

function openOverlay(svg: SVGElement) {
  closeOverlay()

  const vb = (svg.getAttribute('viewBox') || '').split(/\s+/).map(Number)
  const naturalW = vb.length === 4 && vb[2] > 0 ? vb[2] : svg.clientWidth
  const naturalH = vb.length === 4 && vb[3] > 0 ? vb[3] : svg.clientHeight

  const clone = svg.cloneNode(true) as SVGElement
  // 去掉 mermaid 注入的 max-width 限制，按原尺寸摆放
  clone.removeAttribute('style')
  clone.setAttribute('width', String(naturalW))
  clone.setAttribute('height', String(naturalH))
  clone.style.maxWidth = 'none'
  clone.style.width = `${naturalW}px`
  clone.style.height = `${naturalH}px`

  const overlay = document.createElement('div')
  overlay.id = OVERLAY_ID
  overlay.className = 'pb-zoom-overlay'

  const hint = document.createElement('div')
  hint.className = 'pb-zoom-hint'
  hint.textContent = '原尺寸查看 · 点击空白处或按 Esc 关闭'

  const stage = document.createElement('div')
  stage.className = 'pb-zoom-stage'
  stage.appendChild(clone)

  overlay.appendChild(hint)
  overlay.appendChild(stage)
  overlay.addEventListener('click', (e) => {
    if (e.target === overlay || e.target === stage) closeOverlay()
  })

  document.body.appendChild(overlay)
  document.addEventListener('keydown', onKeydown)
}

/** 挂一次全站委托：点到 .mermaid 内的 svg 就开全屏 */
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
