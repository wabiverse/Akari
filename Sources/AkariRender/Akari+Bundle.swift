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

import Foundation

public extension Bundle
{
  /**
   * Resolves plugin resource paths for both bundled and unbundled app contexts,
   * handling both '.bundle' and '.resources' extensions, and the Contents/Resources
   * nesting inside app bundles. */
  static func akariBundle(_ name: String) -> Bundle?
  {
    let akariRoot = Bundle.main.resourcePath ?? ""
    let base = ["\(akariRoot)/\(name).bundle", "\(akariRoot)/\(name).resources"]
      .first { FileManager.default.fileExists(atPath: $0) }
    guard let base else { return nil }

    return Bundle(path: "\(base)/Contents/Resources") ?? Bundle(path: base)
  }
  
  static let akari: Bundle = {
    // in bundled app contexts, swift bundler nests compiled resources under
    // Contents/Resources - check there before falling back to .module.
    if let bundle = akariBundle("Akari_AkariRender")
    { return bundle }
    return .module
  }()
  
  static let hdAkari: Bundle = {
    // in bundled app contexts, swift bundler nests compiled resources under
    // Contents/Resources - check there before falling back to .module.
    if let bundle = akariBundle("Akari_HdAkari")
    { return bundle }
    return .module
  }()
  
  static let fonts: Bundle = {
    // in bundled app contexts, swift bundler nests compiled resources under
    // Contents/Resources - check there before falling back to .module.
    if let bundle = akariBundle("SwiftLabGL_LabGL")
    { return bundle }
    return .module
  }()
}
