#pragma once

#include "Transformer.hpp"

namespace Render {
    class CResizeTransformer : public IWindowTransformer {
      public:
        explicit CResizeTransformer(PHLWINDOWREF window);
        ~CResizeTransformer() override;

        static void            holdLayout(PHLWORKSPACE workspace);
        void                   prepare();
        void                   onCommit();
        void                   reset();
        bool                   active() const override;
        int                    priority() const override;
        SWindowTransformBuffer transform(const SWindowTransformBuffer& in, const SWindowTransformContext& context) override;

      private:
        struct SImage {
            SP<IFramebuffer> framebuffer;
            CBox             windowBox;
            CBox             bufferBox;
            double           scale = 1.0;
        };

        void                resume();
        void                hold();
        bool                ready() const;
        void                finishLayout(bool timeout);

        PHLWINDOWREF        m_window;
        SImage              m_previous;
        SImage              m_latest;
        Vector2D            m_goal;
        bool                m_waiting = false;
        SP<CEventLoopTimer> m_timeout;
    };
}
