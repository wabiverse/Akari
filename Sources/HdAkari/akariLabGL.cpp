/* -----------------------------------------------------------------
 * :: :  A  K  A  R  I  :                                         ::
 * -----------------------------------------------------------------
 * Redistribution  and  use  in  source  and  binary  forms, with or
 * without  modification,  are permitted provided that the following
 * conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 *
 * 2. Redistributions  in  binary  form  must  reproduce  the  above
 *    copyright  notice,  this  list of conditions and the following
 *    disclaimer   in   the  documentation  and/or  other  materials
 *    provided with the distribution.
 *
 * 3. Neither the name of  the copyright holder nor the names of its
 *    contributors  may  be  used  to  endorse  or  promote products
 *    derived  from  this  software  without  specific prior written
 *    permission.
 *
 * THIS   SOFTWARE   IS   PROVIDED  BY  THE  COPYRIGHT  HOLDERS  AND
 * CONTRIBUTORS  "AS  IS"  AND  ANY  EXPRESS  OR IMPLIED WARRANTIES,
 * INCLUDING,   BUT  NOT  LIMITED  TO,  THE  IMPLIED  WARRANTIES  OF
 * MERCHANTABILITY   AND   FITNESS  FOR  A  PARTICULAR  PURPOSE  ARE
 * DISCLAIMED.   IN   NO   EVENT   SHALL  THE  COPYRIGHT  HOLDER  OR
 * CONTRIBUTORS  BE  LIABLE  FOR  ANY  DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL,  EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED  TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF
 * USE,  DATA,  OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED
 * AND  ON  ANY  THEORY  OF  LIABILITY,  WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
 * ANY  WAY  OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 *
 *                               Copyright (C) 2026 Wabi Foundation.
 *                                              All rights reserved.
 * -----------------------------------------------------------------
 *  . x x x . o o o . x x x . : : : .    o  x  o    . : : : .
 * ----------------------------------------------------------------- */
#include "HdAkari/akariBridge.h"
#include "HdAkari/renderParam.h"
#include "HdAkari/scene.h"
#include "akariGeometry.h"

#include <labgl/labgl_capture.h>
#include <labgl/labgl_dispatch.h>

#include <Gf/matrix4d.h>
#include <Gf/matrix4f.h>

#include <vector>

/* LabGL geometry capture for the LabFX opaque geometry pass. */

PXR_NAMESPACE_USING_DIRECTIVE

extern "C" void AkariSceneRecordCapture(void *renderParamPtr, void *captureBuffer,
                                        const float *view, const float *proj)
{
  auto *param = static_cast<HdAkariRenderParam *>(renderParamPtr);
  auto *buf = static_cast<LabGLCaptureBuffer *>(captureBuffer);
  if (!param || !buf || !param->GetScene() || !view || !proj) {
    return;
  }

  std::vector<HdAkariMeshData> meshes = param->GetScene()->Snapshot();
  
  labgl_captureClear(buf);
  labgl_captureStart(buf);

  LABGLDISPATCH_glEnable(GL_DEPTH_TEST);
  LABGLDISPATCH_glDepthFunc(GL_LESS);

  LABGLDISPATCH_glMatrixMode(GL_PROJECTION);
  LABGLDISPATCH_glLoadMatrixf(proj);

  const GfMatrix4d viewM = ToMatrix4d(view);

  std::vector<float> verts;
  std::vector<int> indices;
  for (HdAkariMeshData const &mesh : meshes) {
    if (mesh.points.empty() || mesh.triangleIndices.empty()) {
      continue;
    }

    verts.clear();
    indices.clear();
    BuildMeshGeometry(mesh.points, mesh.triangleIndices, verts, indices);
    if (verts.empty() || indices.empty()) {
      continue;
    }

    LABGLDISPATCH_glMatrixMode(GL_MODELVIEW);
    const GfMatrix4f mv(mesh.transform * viewM);
    LABGLDISPATCH_glLoadMatrixf(mv.GetArray());

    LABGLDISPATCH_glColor3f(mesh.displayColor[0], mesh.displayColor[1],
                            mesh.displayColor[2]);
    LABGLDISPATCH_glBegin(GL_TRIANGLES);
    for (int const idx : indices) {
      const float *v = &verts[static_cast<size_t>(idx) * 6];
      LABGLDISPATCH_glNormal3f(v[3], v[4], v[5]);
      LABGLDISPATCH_glVertex3f(v[0], v[1], v[2]);
    }
    LABGLDISPATCH_glEnd();
  }

  labgl_captureStop();
}
