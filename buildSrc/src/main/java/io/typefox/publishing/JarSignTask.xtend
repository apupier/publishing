/*******************************************************************************
 * Copyright (c) 2016 TypeFox GmbH (http://www.typefox.io) and others.
 * All rights reserved. This program and the accompanying materials
 * are made available under the terms of the Eclipse Public License v1.0
 * which accompanies this distribution, and is available at
 * http://www.eclipse.org/legal/epl-v10.html
 *******************************************************************************/
package io.typefox.publishing

import com.google.common.io.Files
import java.io.File
import java.io.FilenameFilter
import java.io.IOException
import org.eclipse.xtend.lib.annotations.Accessors
import org.gradle.api.DefaultTask
import org.gradle.api.GradleException
import org.gradle.api.file.FileCollection
import org.gradle.api.tasks.InputFiles
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.TaskAction
import org.gradle.api.tasks.incremental.IncrementalTaskInputs

import static extension io.typefox.publishing.FileChecksums.*

/**
 * JAR signing script that follows the instructions at
 *     https://wiki.eclipse.org/JAR_Signing
 * This works only when invoked from the Eclipse build infrastructure.
 */
@Accessors
class JarSignTask extends DefaultTask {
	
	static val SIGNING_SERVICE = 'http://build.eclipse.org:31338/sign'
	
	static val STDOUT_FORMAT = '    %{size_upload} bytes uploaded, %{size_download} bytes downloaded (%{time_total} s)\\n'
	
	@InputFiles
	FileCollection from
	
	@OutputDirectory
	File outputDir
	
	File alternateSourceDir
	
	File alternateTargetDir
	
	boolean failOnInconsistency
	
	@TaskAction
	def void execute(IncrementalTaskInputs inputs) {
		inputs.outOfDate[
			val target = new File(outputDir, file.name)
			processFile(file, target)
		]
	}
	
	private def void processFile(File source, File target) {
		target.parentFile?.mkdirs()
		if (alternateSourceDir !== null) {
			val sourceSuffix = source.name.suffix
			if (sourceSuffix !== null) {
				val sourceArtifactName = source.name.artifactName
				val FilenameFilter filter = [dir, name |
					name.artifactName == sourceArtifactName && name.suffix == sourceSuffix
				]
				val matching = alternateSourceDir.listFiles(filter)
				if (matching.length > 0) {
					val sourceChecksum = source.checksum
					val equalSourceFile = matching.findFirst[checksum == sourceChecksum]
					if (equalSourceFile === null) {
						val message = '''The artifact «source.withoutRootPath» matches «matching.map[withoutRootPath].join(', ')», but their content is unequal.'''
						if (failOnInconsistency)
							throw new GradleException(message)
						else
							logger.warn('Warning: ' + message)
					} else if (alternateTargetDir !== null) {
						val alternateTargetFile = new File(alternateTargetDir, equalSourceFile.name)
						if (alternateTargetFile.exists) {
							logger.lifecycle('''Reusing signed artifact «alternateTargetFile.withoutRootPath»''')
							copyFile(alternateTargetFile, target)
							return
						}
					}
				}
			}
		}
		signFile(source, target)
	}
	
	private def withoutRootPath(File file) {
		if (file.path.startsWith(project.rootDir.path))
			file.path.substring(project.rootDir.path.length + 1)
		else
			file.path
	}
	
	private def getArtifactName(String fileName) {
		val dashIndex = fileName.indexOf('-')
		val underscoreIndex = fileName.indexOf('_')
		val lastDotIndex = fileName.lastIndexOf('.')
		if (dashIndex >= 0 && underscoreIndex >= 0)
			fileName.substring(0, Math.min(dashIndex, underscoreIndex))
		else if (dashIndex >= 0)
			fileName.substring(0, dashIndex)
		else if (underscoreIndex >= 0)
			fileName.substring(0, underscoreIndex)
		else if (lastDotIndex >= 0)
			fileName.substring(0, lastDotIndex)
		else
			fileName
	}
	
	private def getSuffix(String fileName) {
		val matching = MavenPublishing.CLASSIFIERS.map[
			if (key === null)
				'.' + value
			else
				'-' + key + '.' + value
		].filter[fileName.endsWith(it)]
		if (!matching.empty)
			matching.maxBy[length]
	}
	
	private def void signFile(File source, File target) {
		if (project.hasProperty('signing.skip') && project.property('signing.skip') == 'true') {
			logger.lifecycle('''Copy «source.withoutRootPath» (skipped signing)''')
			copyFile(source, target)
		} else {
			logger.lifecycle('''Sign «source.withoutRootPath»''')
			try {
				project.exec[
					executable = 'curl'
					args = #[
						'--fail',
						'--silent', '--show-error',
						'--write-out', STDOUT_FORMAT,
						'--output', target.path,
						'--form', '''file=@«source.path»''',
						SIGNING_SERVICE
					]
				]
			} catch (GradleException exception) {
				// Run again and print the service error message
				try {
					project.exec[
						executable = 'curl'
						args = #[
							'--silent',
							'--form', '''file=@«source.path»''',
							SIGNING_SERVICE
						]
					]
				} catch (GradleException e2) {}
				throw exception
			}
		}
	}
	
	private def void copyFile(File source, File target) {
		try {
			Files.copy(source, target)
		} catch (IOException e) {
			throw new GradleException('''Failed to copy «source.withoutRootPath»''', e)
		}
	}
	
}