import { promises as fs } from 'fs';
import path from 'path';

// Serves the active wallpaper for a mode by following the same
// wallpaper-{mode} symlink the desktop uses, so the editor's canvas shows
// exactly what sits behind the real surfaces.
export async function GET(request: Request) {
  const mode = new URL(request.url).searchParams.get('mode') === 'light' ? 'light' : 'dark';
  const link = path.join(process.cwd(), '..', `wallpaper-${mode}`);

  try {
    const file = await fs.readFile(link);
    const ext = (await fs.realpath(link)).split('.').pop()?.toLowerCase();
    const type = ext === 'jpg' || ext === 'jpeg' ? 'image/jpeg' : 'image/png';
    return new Response(new Uint8Array(file), {
      headers: {
        'Content-Type': type,
        'Cache-Control': 'no-cache',
      },
    });
  } catch {
    return new Response('wallpaper not found', { status: 404 });
  }
}
