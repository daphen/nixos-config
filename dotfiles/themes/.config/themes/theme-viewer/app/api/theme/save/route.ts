import { NextResponse } from 'next/server';
import { promises as fs } from 'fs';
import path from 'path';

export async function POST(request: Request) {
  try {
    const { themeData, mode, surfaceDelta } = await request.json();

    if (!themeData || !mode) {
      return NextResponse.json(
        { error: 'Missing theme data or mode' },
        { status: 400 }
      );
    }

    const colorsPath = path.join(process.cwd(), '..', 'colors.json');
    
    // Read current colors.json
    const currentContent = await fs.readFile(colorsPath, 'utf-8');
    const currentData = JSON.parse(currentContent);
    
    // surface + surface0-3 are derived by theme-processor.py at read time;
    // never persist them or they'd become authored anchors and stop tracking
    // background.primary / the alphas.
    const cleaned = { ...themeData };
    if (cleaned.background) {
      cleaned.background = { ...cleaned.background };
      for (const k of ['surface', 'surface0', 'surface1', 'surface2', 'surface3']) {
        delete cleaned.background[k];
      }
    }

    // Update the specific mode's theme data
    currentData.themes[mode] = cleaned;

    // Persist the surface-derivation knobs (the single source of the ladder).
    if (surfaceDelta && Array.isArray(surfaceDelta.dL)) {
      currentData.surfaces = currentData.surfaces ?? { model: 'oklch-delta' };
      currentData.surfaces[mode] = surfaceDelta;
    }

    // Write back to colors.json
    await fs.writeFile(colorsPath, JSON.stringify(currentData, null, 2), 'utf-8');
    
    return NextResponse.json({ 
      success: true, 
      message: `Theme colors saved to colors.json! Run 'generate_themes' to regenerate the theme files.` 
    });
  } catch (error) {
    console.error('Error saving theme:', error);
    return NextResponse.json(
      { error: 'Failed to save theme' },
      { status: 500 }
    );
  }
}