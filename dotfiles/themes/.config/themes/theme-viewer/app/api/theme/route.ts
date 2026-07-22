import { NextResponse } from 'next/server';
import { promises as fs } from 'fs';
import { execFile } from 'child_process';
import path from 'path';
import { promisify } from 'util';

const execFileAsync = promisify(execFile);

// The surface ladder is derived by theme-processor.py --emit-json, so the
// editor and the generated themes share one source of truth. Falls back to
// the raw file (no derived surfaces) if Python is unavailable.
export async function GET() {
  const themesDir = path.join(process.cwd(), '..');
  const colorsPath = path.join(themesDir, 'colors.json');
  const processor = path.join(themesDir, 'theme-processor.py');

  try {
    const { stdout } = await execFileAsync('python3', [processor, '--emit-json', colorsPath]);
    return NextResponse.json(JSON.parse(stdout));
  } catch (error) {
    console.error('emit-json failed, falling back to raw colors.json:', error);
    try {
      const fileContent = await fs.readFile(colorsPath, 'utf-8');
      return NextResponse.json(JSON.parse(fileContent));
    } catch (readError) {
      console.error('Error reading colors.json:', readError);
      return NextResponse.json(
        { error: 'Failed to read theme colors' },
        { status: 500 },
      );
    }
  }
}
