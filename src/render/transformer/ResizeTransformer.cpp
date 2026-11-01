#include "ResizeTransformer.hpp"

#include "../../desktop/view/window/Window.hpp"
#include "../../desktop/view/window/WindowPresentation.hpp"
#include "../../desktop/view/window/WindowEffectsController.hpp"
#include "../../desktop/state/WindowState.hpp"
#include "../../managers/fullscreen/FullscreenController.hpp"
#include "TransformerList.hpp"
#include "../../managers/eventLoop/EventLoopManager.hpp"
#include "../../managers/eventLoop/EventLoopTimer.hpp"
#include "../../workspace/HLWorkspace.hpp"
#include "../OpenGL.hpp"
#include "../Renderer.hpp"

#include <algorithm>

using namespace Render;

CResizeTransformer::CResizeTransformer(PHLWINDOWREF window) : m_window(window) {
    m_timeout = makeShared<CEventLoopTimer>(std::nullopt, [this](SP<CEventLoopTimer>, void*) { finishLayout(true); }, nullptr);
    g_pEventLoopManager->addTimer(m_timeout);
}

CResizeTransformer::~CResizeTransformer() {
    m_timeout->updateTimeout(std::nullopt);
}

bool CResizeTransformer::active() const {
    const auto window = m_window.lock();
    return window && window->mapped() && m_previous.framebuffer &&
        (m_waiting || (window->sizeAnimation()->isBeingAnimated() && window->sizeAnimation()->value() != window->sizeAnimation()->goal()));
}

int CResizeTransformer::priority() const {
    return -100;
}

static std::vector<PHLWINDOW> layoutWindows(PHLWORKSPACE workspace) {
    std::vector<PHLWINDOW> windows;
    for (const auto& window : Desktop::windowState()->windows()) {
        if (window->mapped() && window->m_workspace == workspace && !window->isFloating() && !Fullscreen::controller()->isFullscreen(window))
            windows.emplace_back(window);
    }
    return windows;
}

void CResizeTransformer::holdLayout(PHLWORKSPACE workspace) {
    const auto windows = layoutWindows(workspace);
    if (!std::ranges::any_of(windows, [](const auto& window) {
            const auto resize = window->effects().transformers()->template get<CResizeTransformer>();
            return resize && resize->m_waiting;
        }))
        return;
    for (const auto& window : windows)
        window->positionAnimation()->disconnectFromActive();
}

bool CResizeTransformer::ready() const {
    const auto window = m_window.lock();
    const auto target = window->backend().logicalToClient(CBox{{}, window->sizeAnimation()->goal()}, window->m_monitor.lock()).size().floor();
    return window->backend().reportedSize() == target && window->backend().geometry().box.size() == target;
}

void CResizeTransformer::finishLayout(bool timeout) {
    const auto owner = m_window.lock();
    if (!owner)
        return;
    const auto windows = layoutWindows(owner->m_workspace);
    std::vector<CResizeTransformer*> pending;
    for (const auto& window : windows) {
        const auto resize = window->effects().transformers()->get<CResizeTransformer>();
        if (resize && resize->m_waiting) {
            if (!timeout && !resize->ready())
                return;
            pending.emplace_back(resize);
        }
    }
    for (const auto resize : pending) {
        if (!resize->ready()) {
            resize->m_previous = {};
            resize->m_latest   = {};
        }
        resize->resume();
    }
    for (const auto& window : windows) {
        if (window->positionAnimation()->value() != window->positionAnimation()->goal()) {
            window->positionAnimation()->onAnimationBegin();
            g_pHyprRenderer->damageWindow(window);
        }
    }
}

void CResizeTransformer::hold() {
    if (const auto window = m_window.lock()) {
        window->positionAnimation()->disconnectFromActive();
        window->sizeAnimation()->disconnectFromActive();
    }
}

void CResizeTransformer::resume() {
    m_timeout->updateTimeout(std::nullopt);
    if (!m_waiting)
        return;

    m_waiting = false;
    if (const auto window = m_window.lock()) {
        window->sizeAnimation()->onAnimationBegin();
        g_pHyprRenderer->damageWindow(window);
    }
}

void CResizeTransformer::reset() {
    m_timeout->updateTimeout(std::nullopt);
    const bool waiting = m_waiting;
    if (m_waiting) {
        m_waiting = false;
        if (const auto window = m_window.lock()) {
            window->positionAnimation()->connectToActive();
            window->sizeAnimation()->connectToActive();
            g_pHyprRenderer->damageWindow(window);
        }
    }
    m_previous = {};
    m_latest   = {};
    if (waiting)
        finishLayout(false);
}

void CResizeTransformer::prepare() {
    const auto window  = m_window.lock();
    const auto monitor = window->m_monitor.lock();
    if (m_previous.framebuffer && m_goal == window->sizeAnimation()->goal()) {
        if (m_waiting)
            hold();
        return;
    }

    if (window->sizeAnimation()->value() == window->sizeAnimation()->goal()) {
        reset();
        return;
    }

    if (!m_waiting && m_latest.framebuffer)
        m_previous = std::move(m_latest);
    if (!m_previous.framebuffer) {
        SImage image;
        image.scale       = monitor->m_scale;
        const auto offset = ((window->m_state & Desktop::View::WINDOW_STATE_PINNED) ? Vector2D{} : window->m_workspace->m_renderOffset->value()) +
            window->presentation().floatingOffset() - monitor->m_position;
        image.windowBox   = window->geometricBox(Desktop::View::IGeometric::GEOMETRIC_CURRENT).translate(offset);
        image.bufferBox   = pixelBoxForLogical(window->getFullWindowBoundingBox().translate(offset).expand(1.0 / image.scale), image.scale);
        image.framebuffer = g_pHyprRenderer->makeSnapshotFB(window, image.bufferBox);
        if (!image.framebuffer)
            return;
        m_previous = std::move(image);
    }

    m_latest = {};
    m_goal   = window->sizeAnimation()->goal();
    if (!m_waiting)
        m_timeout->updateTimeout(std::chrono::milliseconds(300));
    m_waiting = true;
    hold();
    g_pHyprRenderer->damageWindow(window);
}

void CResizeTransformer::onCommit() {
    if (m_waiting)
        finishLayout(false);
}

SWindowTransformBuffer CResizeTransformer::transform(const SWindowTransformBuffer& in, const SWindowTransformContext& context) {
    const auto window  = m_window.lock();
    const auto monitor = context.monitor.lock();
    if (!window || !monitor || !in.framebuffer)
        return in;

    const auto outputBox = pixelBoxForLogical(context.outputBox.copy().expand(1.0 / monitor->m_scale), monitor->m_scale);
    const auto output    = monitor->resources()->getUnusedWorkBuffer(outputBox.size());
    if (!output) {
        reset();
        return {.framebuffer = in.framebuffer, .box = in.box, .success = false};
    }

    const auto currentBox  = window->geometricBox(Desktop::View::IGeometric::GEOMETRIC_CURRENT).translate(context.currentBox.pos() - window->getFullWindowBoundingBox().pos());
    const auto ratio       = currentBox.size() / m_previous.windowBox.size();
    const CBox previousBox = {
        (currentBox.pos() + (m_previous.bufferBox.pos() / m_previous.scale - m_previous.windowBox.pos()) * ratio) * monitor->m_scale - outputBox.pos(),
        m_previous.bufferBox.size() * ratio * (monitor->m_scale / m_previous.scale),
    };
    const float progress   = m_waiting ? 0.F : std::clamp(window->sizeAnimation()->getCurveValue(), 0.F, 1.F);
    auto&       renderData = g_pHyprRenderer->m_renderData;
    const auto  saved      = renderData;
    {
        auto guard             = g_pHyprRenderer->bindTempFB(output);
        renderData.damage      = CRegion{0, 0, sc<int>(outputBox.w), sc<int>(outputBox.h)};
        renderData.fbSize      = outputBox.size();
        renderData.renderModif = {};
        g_pHyprRenderer->setProjectionType(RPT_EXPORT);
        g_pHyprRenderer->draw(CClearPassElement::SClearData{CHyprColor(0, 0, 0, 0)});
        // Weighted addition preserves premultiplied alpha, including translucent clients.
        g_pHyprRenderer->blend(true);
        GL::g_pHyprOpenGL->blendFunc(GL_ONE, GL_ONE);
        g_pHyprRenderer->draw(
            CTexPassElement::SRenderData{
                .tex = in.framebuffer->getTexture(),
                .box = in.box.copy().translate(-outputBox.pos()),
                .a   = progress,
            },
            renderData.damage);
        g_pHyprRenderer->draw(
            CTexPassElement::SRenderData{
                .tex = m_previous.framebuffer->getTexture(),
                .box = previousBox,
                .a   = 1.F - progress,
            },
            renderData.damage);
        GL::g_pHyprOpenGL->blendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    }
    renderData = saved;
    g_pHyprRenderer->setProjectionType(saved.projectionType);
    if (!m_waiting)
        m_latest = {.framebuffer = output, .windowBox = currentBox, .bufferBox = outputBox, .scale = monitor->m_scale};
    return {.framebuffer = output, .box = outputBox};
}
